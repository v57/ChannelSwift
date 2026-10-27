//
//  TLSSocket.swift
//  ChannelSwift
//
//  TLS over a connected TCP socket, for SocketWebSocketTask's wss:// off Apple platforms: OpenSSL with memory BIOs,
//  so the socket I/O stays SocketWebSocketTask's kind (send with MSG_NOSIGNAL, blocking recv on its own thread).
//

#if canImport(COpenSSL)
import COpenSSL
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A TLS client session on `socket`: the system's roots (or `SSL_CERT_FILE` / `SSL_CERT_DIR`), the server's name or
/// address checked against its certificate, SNI, TLS 1.2 or later. One thread reads while others write: each OpenSSL
/// call runs under one lock, the socket is read outside it, and records leave in the order OpenSSL made them.
final class TLSSocket: @unchecked Sendable {
  private let context: OpaquePointer
  private let ssl: OpaquePointer
  /// Ciphertext from the socket for OpenSSL, and from OpenSSL for the socket (owned by `ssl`).
  private let input: OpaquePointer
  private let output: OpaquePointer
  private let socket: Int32
  private let lock = NSLock()
  private let sendLock = NSLock()

  /// Connects TLS on `socket` (connected, blocking) to `host`; throws when the handshake or the certificate fails.
  init(socket: Int32, host: String) throws {
    self.socket = socket
    guard let context = SSL_CTX_new(TLS_client_method()) else { throw SocketWebSocketTask.Failure("TLS unavailable") }
    self.context = context
    _ = channel_ssl_ctx_set_min_tls12(context)
    SSL_CTX_set_verify(context, SSL_VERIFY_PEER, nil)
    SSL_CTX_set_default_verify_paths(context)
    guard let ssl = SSL_new(context), let input = BIO_new(BIO_s_mem()), let output = BIO_new(BIO_s_mem()) else {
      SSL_CTX_free(context)
      throw SocketWebSocketTask.Failure("TLS unavailable")
    }
    self.ssl = ssl
    self.input = input
    self.output = output
    SSL_set_bio(ssl, input, output)
    SSL_set_connect_state(ssl)
    let name = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    if Self.isAddress(name) {
      X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), name)
    } else {
      _ = channel_ssl_set_server_name(ssl, name)
      SSL_set1_host(ssl, name)
    }
    try handshake()
  }

  deinit {
    SSL_free(ssl)  // frees the BIOs too
    SSL_CTX_free(context)
  }

  private static func isAddress(_ host: String) -> Bool {
    var v4 = in_addr()
    var v6 = in6_addr()
    return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
  }

  private func handshake() throws {
    while true {
      let (result, error) = lock.withLock { () -> (Int32, Int32) in
        let result = SSL_do_handshake(ssl)
        return (result, result == 1 ? 0 : SSL_get_error(ssl, result))
      }
      try flush()
      if result == 1 { return }
      guard error == SSL_ERROR_WANT_READ else {
        let verify = SSL_get_verify_result(ssl)
        if verify != X509_V_OK {
          throw SocketWebSocketTask.Failure(
            "TLS: the server's certificate isn't trusted (\(String(cString: X509_verify_cert_error_string(verify))))")
        }
        throw SocketWebSocketTask.Failure("TLS handshake failed: \(Self.lastError())")
      }
      guard try receive() else { throw SocketWebSocketTask.Failure("connection closed during the TLS handshake") }
    }
  }

  /// Plaintext into `buffer`: the count, or 0 once the server closed the connection.
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    while true {
      let (count, error) = lock.withLock { () -> (Int32, Int32) in
        let count = SSL_read(ssl, buffer.baseAddress, Int32(clamping: buffer.count))
        return (count, count > 0 ? 0 : SSL_get_error(ssl, count))
      }
      // Reading can answer the server (TLS 1.3 key updates).
      try flush()
      if count > 0 { return Int(count) }
      switch error {
      case SSL_ERROR_WANT_READ:
        guard try receive() else { return 0 }
      case SSL_ERROR_ZERO_RETURN:
        return 0
      default:
        throw SocketWebSocketTask.Failure("TLS read failed: \(Self.lastError())")
      }
    }
  }

  /// Encrypts `data` and sends it.
  func write(_ data: Data) throws {
    try lock.withLock {
      try data.withUnsafeBytes { bytes in
        var written = 0
        while written < bytes.count {
          let count = SSL_write(ssl, bytes.baseAddress! + written, Int32(clamping: bytes.count - written))
          guard count > 0 else { throw SocketWebSocketTask.Failure("TLS write failed: \(Self.lastError())") }
          written += Int(count)
        }
      }
    }
    try flush()
  }

  /// Ciphertext from the socket into OpenSSL; false when the connection closed.
  private func receive() throws -> Bool {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
      if count > 0 {
        lock.withLock { _ = chunk.withUnsafeBytes { BIO_write(input, $0.baseAddress, Int32(count)) } }
        return true
      }
      if count < 0 && errno == EINTR { continue }
      if count == 0 { return false }
      throw SocketWebSocketTask.Failure("read failed (\(errno))")
    }
  }

  /// Sends what OpenSSL has written, in order (one sender at a time takes and sends).
  private func flush() throws {
    sendLock.lock()
    defer { sendLock.unlock() }
    #if canImport(Glibc)
    let flags = Int32(MSG_NOSIGNAL)
    #else
    let flags: Int32 = 0
    #endif
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = lock.withLock { chunk.withUnsafeMutableBytes { BIO_read(output, $0.baseAddress, Int32($0.count)) } }
      guard count > 0 else { return }
      try chunk.withUnsafeBytes { bytes in
        var sent = 0
        while sent < Int(count) {
          let result = send(socket, bytes.baseAddress! + sent, Int(count) - sent, flags)
          if result < 0 && errno == EINTR { continue }
          guard result > 0 else { throw SocketWebSocketTask.Failure("write failed (\(errno))") }
          sent += result
        }
      }
    }
  }

  private static func lastError() -> String {
    let code = ERR_get_error()
    guard code != 0 else { return "unknown error" }
    var buffer = [CChar](repeating: 0, count: 256)
    ERR_error_string_n(code, &buffer, buffer.count)
    return String(cString: buffer)
  }
}
#endif
