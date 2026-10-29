//
//  QUICTask.swift
//  ChannelSwift
//
//  Channel over QUIC (`quic://host:port`, docs/quic.md in the TypeScript reference): one bidirectional stream per
//  connection carrying the same JSON messages as a WebSocket, each one prefixed with its length as a QUIC
//  variable-length integer. On Network.framework, so on Apple platforms from macOS 12 and iOS 15; elsewhere a
//  `quic://` address fails to connect and WebSocket stays the transport.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
import Security
import CryptoKit
#endif

/// Certificate trust for `quic://` addresses. Without `ca` or `fingerprint` the server certificate must be trusted by
/// the system.
public struct QUICOptions: Sendable {
  /// A PEM (or DER) certificate or CA to trust, for self-signed servers. The address must be in its subject
  /// alternative names, as a DNS name or an IP address.
  public var ca: Data?
  /// SHA-256 fingerprint of the server certificate (hex, colons optional) to accept instead of verifying it
  public var fingerprint: String?
  /// Overrides the name sent and checked, which defaults to the address host
  public var serverName: String?

  public init(ca: Data? = nil, fingerprint: String? = nil, serverName: String? = nil) {
    self.ca = ca
    self.fingerprint = fingerprint
    self.serverName = serverName
  }
}

/// The QUIC transport's wire constants and framing
enum QUICFrame {
  static let alpn = "channel/1"
  /// Silent connections close after this many seconds; clients send an empty frame every 15 s (the ping interval)
  static let idleTimeout = 30

  /// The length of `payload` as a QUIC variable-length integer (RFC 9000 §16), then `payload`
  static func encode(_ payload: Data) -> Data {
    let n = UInt64(payload.count)
    var frame: Data
    switch n {
    case ..<(1 << 6): frame = Data([UInt8(n)])
    case ..<(1 << 14): frame = Data([UInt8(n >> 8) | 0x40, UInt8(n & 0xff)])
    case ..<(1 << 30): frame = Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }); frame[0] |= 0x80
    default: frame = Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }); frame[0] |= 0xc0
    }
    frame.append(payload)
    return frame
  }

  struct TooLarge: Error {}

  /// Takes the complete frames off the front of `buffer`; empty frames (keepalives) are skipped
  static func decode(_ buffer: inout Data, maximum: Int) throws -> [Data] {
    var frames = [Data]()
    var offset = buffer.startIndex
    while offset < buffer.endIndex {
      let size = 1 << (buffer[offset] >> 6)
      guard buffer.endIndex - offset >= size else { break }
      var length = UInt64(buffer[offset] & 0x3f)
      for i in 1..<size { length = length << 8 | UInt64(buffer[offset + i]) }
      guard length <= UInt64(maximum) else { throw TooLarge() }
      guard UInt64(buffer.endIndex - offset - size) >= length else { break }
      let start = offset + size
      if length > 0 { frames.append(buffer.subdata(in: start..<start + Int(length))) }
      offset = start + Int(length)
    }
    buffer.removeSubrange(buffer.startIndex..<offset)
    return frames
  }
}

struct QUICFailure: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

#if canImport(Network)
/// Checks the server certificate: pinned by its SHA-256, or against `ca` or the system roots for the server name
struct QUICTrust: Sendable {
  private let pin: Data?
  private let anchors: [Data]
  let serverName: String

  init(_ options: QUICOptions, host: String) throws {
    serverName = options.serverName ?? host
    if let fingerprint = options.fingerprint {
      let hex = fingerprint.replacingOccurrences(of: ":", with: "")
      var bytes = Data()
      var index = hex.startIndex
      while index < hex.endIndex, let end = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
            let byte = UInt8(hex[index..<end], radix: 16) {
        bytes.append(byte)
        index = end
      }
      guard index == hex.endIndex, bytes.count == 32 else {
        throw QUICFailure("fingerprint isn't a SHA-256 in hex: \(fingerprint)")
      }
      pin = bytes
    } else {
      pin = nil
    }
    anchors = try options.ca.map(Self.certificates) ?? []
  }

  /// The DER certificates in PEM text, or `data` itself when it isn't PEM
  static func certificates(_ data: Data) throws -> [Data] {
    let text = String(decoding: data, as: UTF8.self)
    guard text.contains("-----BEGIN CERTIFICATE-----") else { return [data] }
    let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
    let certificates = blocks.compactMap { block in
      block.components(separatedBy: "-----END CERTIFICATE-----").first
        .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }
    guard !certificates.isEmpty else { throw QUICFailure("ca has no PEM certificate") }
    return certificates
  }

  func verify(_ trust: SecTrust) -> Bool {
    if let pin {
      // Pinning replaces the other checks, as in the TypeScript client
      guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
      return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pin
    }
    SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, serverName as CFString))
    if !anchors.isEmpty {
      let certificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
      SecTrustSetAnchorCertificates(trust, certificates as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, true)
    }
    return SecTrustEvaluateWithError(trust, nil)
  }
}

/// One QUIC connection attempt of a WebSocketClient, with URLSessionWebSocketTask's API: the headers go in the first
/// frame (`{"hello": headers}`), pings are empty frames
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
final class QUICTask: WebSocketTask, @unchecked Sendable {
  /// Called once the stream is open and the hello sent, on the connection's queue
  var onOpen: (@Sendable () -> Void)?
  /// Called once when an open connection closes, on any queue
  var onClose: (@Sendable () -> Void)?

  private let request: URLRequest
  private let maximumMessageSize: Int
  private let options: QUICOptions
  private let queue = DispatchQueue(label: "channel.quic")
  private let lock = NSLock()
  private var connection: NWConnection?
  private var buffer = Data()
  private var isOpen = false
  private var isFinished = false
  private var messages: [URLSessionWebSocketTask.Message] = []
  private var receivers: [@Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void] = []
  private var failure: (any Error)?

  init(request: URLRequest, maximumMessageSize: Int, options: QUICOptions) {
    self.request = request
    self.maximumMessageSize = maximumMessageSize
    self.options = options
  }

  var response: URLResponse? { nil }

  func resume() {
    do {
      guard let url = request.url, let host = url.host, let port = url.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) })
      else { throw QUICFailure("expected quic://host:port") }
      let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      let trust = try QUICTrust(options, host: address)
      let quic = NWProtocolQUIC.Options(alpn: [QUICFrame.alpn])
      quic.direction = .bidirectional
      quic.idleTimeout = QUICFrame.idleTimeout * 1000
      let security = quic.securityProtocolOptions
      sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
      // No SNI for an address, as TLS requires; the certificate is still checked against it
      if options.serverName != nil || (IPv4Address(address) == nil && IPv6Address(address) == nil) {
        sec_protocol_options_set_tls_server_name(security, trust.serverName)
      }
      sec_protocol_options_set_verify_block(security, { _, secTrust, complete in
        complete(trust.verify(sec_trust_copy_ref(secTrust).takeRetainedValue()))
      }, queue)
      // NWParameters.allowFastOpen stays off: no 0-RTT, since a replayed early request could run twice
      let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: NWParameters(quic: quic))
      lock.withLock { self.connection = connection }
      connection.stateUpdateHandler = { [weak self, weak connection] state in
        guard let self, let connection else { return }
        switch state {
        case .ready: self.opened(connection)
        case .waiting(let error), .failed(let error): self.finish(error)
        case .cancelled: self.finish(QUICFailure("closed"))
        default: break
        }
      }
      connection.start(queue: queue)
    } catch {
      finish(error)
    }
  }

  private func opened(_ connection: NWConnection) {
    let headers = request.allHTTPHeaderFields ?? [:]
    let hello = (try? JSONSerialization.data(withJSONObject: ["hello": headers])) ?? Data(#"{"hello":{}}"#.utf8)
    connection.send(content: QUICFrame.encode(hello), completion: .contentProcessed { _ in })
    guard lock.withLock({ () -> Bool in
      guard !isFinished else { return false }
      isOpen = true
      return true
    }) else { return }
    receive(on: connection)
    onOpen?()
  }

  private func receive(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data {
        do {
          buffer.append(data)
          for frame in try QUICFrame.decode(&buffer, maximum: maximumMessageSize) {
            deliver(.string(String(decoding: frame, as: UTF8.self)))
          }
        } catch {
          return finish(QUICFailure("message too big"))
        }
      }
      if let error { return finish(error) }
      if isComplete { return finish(QUICFailure("closed by the server")) }
      receive(on: connection)
    }
  }

  func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void) {
    lock.lock()
    if !messages.isEmpty {
      let message = messages.removeFirst()
      lock.unlock()
      completionHandler(.success(message))
    } else if let failure {
      lock.unlock()
      completionHandler(.failure(failure))
    } else {
      receivers.append(completionHandler)
      lock.unlock()
    }
  }

  func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
    guard case .string(let text) = message else { return completionHandler(QUICFailure("binary messages aren't sent")) }
    write(Data(text.utf8), completionHandler)
  }

  /// An empty frame, the transport's keepalive. QUIC has no pong, so the handler runs once the frame is handed to the
  /// connection; a dead connection ends with the QUIC idle timeout.
  func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
    write(Data(), pongReceiveHandler)
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    finish(QUICFailure("cancelled"), notify: false)
  }

  private func write(_ payload: Data, _ completion: @escaping @Sendable ((any Error)?) -> Void) {
    guard let connection = lock.withLock({ isOpen && !isFinished ? connection : nil }) else {
      return completion(failure ?? QUICFailure("not connected"))
    }
    connection.send(content: QUICFrame.encode(payload), completion: .contentProcessed { error in completion(error) })
  }

  private func deliver(_ message: URLSessionWebSocketTask.Message) {
    lock.lock()
    if receivers.isEmpty {
      messages.append(message)
      lock.unlock()
    } else {
      let receiver = receivers.removeFirst()
      lock.unlock()
      receiver(.success(message))
    }
  }

  private func finish(_ error: any Error, notify: Bool = true) {
    lock.lock()
    guard !isFinished else { return lock.unlock() }
    isFinished = true
    failure = error
    let wasOpen = isOpen
    let waiting = receivers
    receivers = []
    let connection = self.connection
    lock.unlock()
    connection?.cancel()
    for receiver in waiting { receiver(.failure(error)) }
    if notify && wasOpen { onClose?() }
  }
}
#endif

/// A `quic://` attempt where Network.framework's QUIC is missing: it fails at once, so the client keeps retrying with
/// its backoff
final class UnavailableQUICTask: WebSocketTask, @unchecked Sendable {
  private let failure = QUICFailure("QUIC needs Network.framework (macOS 12, iOS 15, tvOS 15, watchOS 8 or later)")
  var response: URLResponse? { nil }
  func resume() {}
  func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void) {
    completionHandler(.failure(failure))
  }
  func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
    completionHandler(failure)
  }
  func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
    pongReceiveHandler(failure)
  }
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}
