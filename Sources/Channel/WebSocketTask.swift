//
//  WebSocketTask.swift
//  ChannelSwift
//
//  One WebSocket connection attempt of a WebSocketClient: URLSession's task where URLSession speaks WebSocket, and
//  SocketWebSocketTask where it can't (swift-corelibs-foundation on a libcurl built without WebSockets, as Ubuntu
//  24.04's 8.5 is: "WebSockets not supported by libcurl"), with TLSSocket for wss:// where OpenSSL is linked.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What WebSocketClient needs from a connection: URLSessionWebSocketTask's API
protocol WebSocketTask: AnyObject, Sendable {
  /// The upgrade response, once the server answered
  var response: URLResponse? { get }
  func resume()
  func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void)
  func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void)
  func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void)
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: WebSocketTask {}

#if canImport(Darwin) || canImport(Glibc)
/// The WebSocket protocol (RFC 6455) over a TCP socket, for `ws://` addresses and, through TLSSocket (OpenSSL),
/// `wss://`: a thread per connection connects, sends the upgrade request, checks the server's Sec-WebSocket-Accept,
/// then reads frames.
final class SocketWebSocketTask: WebSocketTask, @unchecked Sendable {
  /// Whether `url` needs this task instead of URLSession's: `ws://` off Apple platforms, and `wss://` where OpenSSL is
  /// linked (Linux)
  static func isNeeded(for url: URL) -> Bool {
    #if canImport(Darwin)
    false
    #elseif canImport(COpenSSL)
    ["ws", "wss"].contains(url.scheme?.lowercased())
    #else
    url.scheme?.lowercased() == "ws"
    #endif
  }

  struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
  }

  /// Called once the server accepted the upgrade, on the connection's thread
  var onOpen: (@Sendable () -> Void)?
  /// Called once when an open connection closes, on any thread
  var onClose: (@Sendable () -> Void)?

  private let request: URLRequest
  private let maximumMessageSize: Int
  private let lock = NSLock()
  private let writeLock = NSLock()
  private var descriptor: Int32 = -1
  #if canImport(COpenSSL)
  /// The TLS session of a `wss://` connection
  private var tls: TLSSocket?
  #endif
  private var isOpen = false
  private var isFinished = false
  private var _response: URLResponse?
  private var messages: [URLSessionWebSocketTask.Message] = []
  private var receivers: [@Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void] = []
  private var pongHandlers: [@Sendable ((any Error)?) -> Void] = []
  private var failure: (any Error)?

  init(request: URLRequest, maximumMessageSize: Int) {
    self.request = request
    self.maximumMessageSize = maximumMessageSize
  }

  var response: URLResponse? { lock.withLock { _response } }

  func resume() {
    let thread = Thread { [self] in run() }
    thread.name = "channel.websocket"
    thread.start()
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
    switch message {
    case .string(let text): completionHandler(write(opcode: 0x1, Data(text.utf8)))
    case .data(let data): completionHandler(write(opcode: 0x2, data))
    @unknown default: completionHandler(Failure("unsupported message"))
    }
  }

  func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
    lock.withLock { pongHandlers.append(pongReceiveHandler) }
    if let error = write(opcode: 0x9, Data()) {
      let handlers = lock.withLock { () -> [@Sendable ((any Error)?) -> Void] in
        defer { pongHandlers = [] }
        return pongHandlers
      }
      for handler in handlers { handler(error) }
    }
  }

  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    var payload = Data([UInt8(closeCode.rawValue >> 8 & 0xff), UInt8(closeCode.rawValue & 0xff)])
    if let reason { payload.append(reason.prefix(123)) }
    if lock.withLock({ isOpen && !isFinished }) { _ = write(opcode: 0x8, payload) }
    finish(Failure("cancelled"), notify: false)
  }

  // MARK: Connection

  private func run() {
    do {
      guard let url = request.url, let host = url.host else { throw Failure("invalid url") }
      let secure = url.scheme?.lowercased() == "wss"
      let socket = try Self.connect(host: host, port: url.port ?? (secure ? 443 : 80))
      lock.lock()
      if isFinished {
        lock.unlock()
        close(socket)
        return
      }
      descriptor = socket
      lock.unlock()
      if secure {
        #if canImport(COpenSSL)
        let tls = try TLSSocket(socket: socket, host: host)
        lock.withLock { self.tls = tls }
        #else
        throw Failure("wss:// needs TLS, which this build lacks")
        #endif
      }
      var buffer = try handshake(url: url, host: host)
      lock.withLock { isOpen = true }
      onOpen?()
      try readFrames(&buffer)
    } catch {
      finish(error, notify: true)
    }
  }

  private static func connect(host: String, port: Int) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    #if canImport(Glibc)
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #else
    hints.ai_socktype = SOCK_STREAM
    #endif
    var info: UnsafeMutablePointer<addrinfo>?
    let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    guard getaddrinfo(bare, String(port), &hints, &info) == 0, let first = info else {
      throw Failure("can't resolve \(host)")
    }
    defer { freeaddrinfo(info) }
    var next: UnsafeMutablePointer<addrinfo>? = first
    while let address = next {
      let socket = c_socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
      if socket >= 0 {
        if c_connect(socket, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
          var on: Int32 = 1
          setsockopt(socket, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
          #if canImport(Darwin)
          setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
          #endif
          return socket
        }
        close(socket)
      }
      next = address.pointee.ai_next
    }
    throw Failure("can't connect to \(host):\(port)")
  }

  /// Sends the upgrade request and reads the answer; returns what came after it
  private func handshake(url: URL, host: String) throws -> Data {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    var path = url.path.isEmpty ? "/" : url.path
    if let query = url.query { path += "?" + query }
    let hostField = url.port.map { "\(host):\($0)" } ?? host
    var lines = ["GET \(path) HTTP/1.1", "Host: \(hostField)", "Upgrade: websocket", "Connection: Upgrade",
      "Sec-WebSocket-Key: \(key)", "Sec-WebSocket-Version: 13"]
    let reserved: Set<String> = ["host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version"]
    for (name, value) in request.allHTTPHeaderFields ?? [:] where !reserved.contains(name.lowercased()) {
      lines.append("\(name): \(value)")
    }
    try writeAll(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    var buffer = Data()
    let end = Data("\r\n\r\n".utf8)
    while buffer.range(of: end) == nil {
      guard buffer.count < 64 * 1024 else { throw Failure("upgrade response too long") }
      try read(into: &buffer)
    }
    let range = buffer.range(of: end)!
    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let status = head.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
    var fields: [String: String] = [:]
    for line in head.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    lock.withLock { _response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields) }
    guard status == 101 else { throw Failure("upgrade refused with HTTP \(status)") }
    // The server proves it read this request (RFC 6455 4.1): base64(SHA-1(key + the protocol's GUID))
    let accept = fields.first { $0.key.lowercased() == "sec-websocket-accept" }?.value
    guard accept == Self.acceptValue(for: key) else { throw Failure("the server's Sec-WebSocket-Accept doesn't match") }
    return Data(buffer[range.upperBound...])
  }

  private func readFrames(_ buffer: inout Data) throws {
    var fragments = Data()
    var fragmentOpcode: UInt8 = 0
    while true {
      while buffer.count < 2 { try read(into: &buffer) }
      let bytes = [UInt8](buffer.prefix(14))
      let fin = bytes[0] & 0x80 != 0
      let opcode = bytes[0] & 0x0f
      let masked = bytes[1] & 0x80 != 0
      var length = Int(bytes[1] & 0x7f)
      var offset = 2
      if length == 126 {
        while buffer.count < 4 { try read(into: &buffer) }
        let b = [UInt8](buffer.prefix(4))
        length = Int(b[2]) << 8 | Int(b[3])
        offset = 4
      } else if length == 127 {
        while buffer.count < 10 { try read(into: &buffer) }
        let b = [UInt8](buffer.prefix(10))
        length = b[2..<10].reduce(0) { $0 << 8 | Int($1) }
        offset = 10
      }
      guard length <= maximumMessageSize, fragments.count + length <= maximumMessageSize else {
        throw Failure("message too large")
      }
      let maskOffset = offset
      if masked { offset += 4 }
      while buffer.count < offset + length { try read(into: &buffer) }
      var payload = Data(buffer[buffer.startIndex + offset..<buffer.startIndex + offset + length])
      if masked {
        let mask = [UInt8](buffer[buffer.startIndex + maskOffset..<buffer.startIndex + maskOffset + 4])
        payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
      }
      buffer = Data(buffer[(buffer.startIndex + offset + length)...])
      switch opcode {
      case 0x0, 0x1, 0x2:
        if opcode != 0 { fragmentOpcode = opcode }
        fragments.append(payload)
        guard fin else { continue }
        let message: URLSessionWebSocketTask.Message =
          fragmentOpcode == 0x1 ? .string(String(decoding: fragments, as: UTF8.self)) : .data(fragments)
        fragments = Data()
        deliver(message)
      case 0x8:
        _ = write(opcode: 0x8, payload.prefix(2))
        throw Failure("closed by the server")
      case 0x9:
        _ = write(opcode: 0xA, payload)
      case 0xA:
        let handlers = lock.withLock { () -> [@Sendable ((any Error)?) -> Void] in
          defer { pongHandlers = [] }
          return pongHandlers
        }
        for handler in handlers { handler(nil) }
      default:
        throw Failure("unknown opcode \(opcode)")
      }
    }
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

  /// Ends the connection: fails the waiting receivers and pings, and tells `onClose` if it was open
  private func finish(_ error: any Error, notify: Bool) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    failure = error
    let wasOpen = isOpen
    let socket = descriptor
    descriptor = -1
    let receivers = self.receivers
    self.receivers = []
    let pongs = pongHandlers
    pongHandlers = []
    lock.unlock()
    if socket >= 0 {
      shutdown(socket, Int32(SHUT_RDWR))
      close(socket)
    }
    for receiver in receivers { receiver(.failure(error)) }
    for pong in pongs { pong(error) }
    if notify && wasOpen { onClose?() }
  }

  // MARK: Socket I/O

  private func read(into buffer: inout Data) throws {
    let socket = lock.withLock { descriptor }
    guard socket >= 0 else { throw Failure("closed") }
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    #if canImport(COpenSSL)
    if let tls = lock.withLock({ tls }) {
      let count = try chunk.withUnsafeMutableBytes { try tls.read(into: $0) }
      guard count > 0 else { throw Failure("connection closed") }
      buffer.append(contentsOf: chunk[0..<count])
      return
    }
    #endif
    while true {
      let count = chunk.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
      if count > 0 {
        buffer.append(contentsOf: chunk[0..<count])
        return
      }
      if count < 0 && errno == EINTR { continue }
      throw Failure(count == 0 ? "connection closed" : "read failed (\(errno))")
    }
  }

  /// One frame from the client: always masked (RFC 6455 5.3)
  private func write(opcode: UInt8, _ payload: Data) -> (any Error)? {
    var frame = Data([0x80 | opcode])
    if payload.count < 126 {
      frame.append(0x80 | UInt8(payload.count))
    } else if payload.count <= 0xffff {
      frame.append(0x80 | 126)
      frame.append(contentsOf: [UInt8(payload.count >> 8 & 0xff), UInt8(payload.count & 0xff)])
    } else {
      frame.append(0x80 | 127)
      frame.append(contentsOf: (0..<8).reversed().map { UInt8(payload.count >> ($0 * 8) & 0xff) })
    }
    let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
    frame.append(contentsOf: mask)
    frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    do {
      try writeAll(frame)
      return nil
    } catch {
      return error
    }
  }

  private func writeAll(_ data: Data) throws {
    writeLock.lock()
    defer { writeLock.unlock() }
    let socket = lock.withLock { descriptor }
    guard socket >= 0 else { throw Failure("not connected") }
    #if canImport(COpenSSL)
    if let tls = lock.withLock({ tls }) { return try tls.write(data) }
    #endif
    #if canImport(Glibc)
    let flags = Int32(MSG_NOSIGNAL)
    #else
    let flags: Int32 = 0
    #endif
    try data.withUnsafeBytes { bytes in
      var sent = 0
      while sent < bytes.count {
        let count = c_send(socket, bytes.baseAddress! + sent, bytes.count - sent, flags)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw Failure("write failed (\(errno))") }
        sent += count
      }
    }
  }
}

extension SocketWebSocketTask {
  /// The Sec-WebSocket-Accept a server answers `key` with: base64(SHA-1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  static func acceptValue(for key: String) -> String {
    Data(sha1(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
  }

  /// SHA-1 (FIPS 180-4), only for the handshake's check: Foundation has no digests off Apple platforms
  static func sha1(_ message: [UInt8]) -> [UInt8] {
    var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    var bytes = message
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    let bits = UInt64(message.count) * 8
    bytes.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
    var w = [UInt32](repeating: 0, count: 80)
    for chunk in stride(from: 0, to: bytes.count, by: 64) {
      for i in 0..<16 {
        let j = chunk + i * 4
        w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
      }
      for i in 16..<80 {
        let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
        w[i] = x << 1 | x >> 31
      }
      var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
      for i in 0..<80 {
        let (f, k): (UInt32, UInt32) =
          switch i {
          case 0..<20: (b & c | ~b & d, 0x5A82_7999)
          case 20..<40: (b ^ c ^ d, 0x6ED9_EBA1)
          case 40..<60: (b & c | b & d | c & d, 0x8F1B_BCDC)
          default: (b ^ c ^ d, 0xCA62_C1D6)
          }
        let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
        (e, d, c, b, a) = (d, c, b << 30 | b >> 2, a, t)
      }
      h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
    }
    return h.flatMap { value in (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  }
}

// The C calls by their module, since the task has methods of the same names
#if canImport(Glibc)
private let c_socket = Glibc.socket
private let c_connect = Glibc.connect
private let c_send = Glibc.send
#else
private let c_socket = Darwin.socket
private let c_connect = Darwin.connect
private let c_send = Darwin.send
#endif
#else
/// Off Apple platforms and Linux URLSession's task is the only one
final class SocketWebSocketTask: WebSocketTask, @unchecked Sendable {
  static func isNeeded(for url: URL) -> Bool { false }
  var onOpen: (@Sendable () -> Void)?
  var onClose: (@Sendable () -> Void)?
  init(request: URLRequest, maximumMessageSize: Int) {}
  var response: URLResponse? { nil }
  func resume() {}
  func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void) {}
  func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {}
  func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {}
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}
#endif
