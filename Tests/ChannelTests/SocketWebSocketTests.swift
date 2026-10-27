import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Channel

/// SocketWebSocketTask: the handshake's Sec-WebSocket-Accept check, and, given servers in the environment, wss:// and
/// refused servers (Linux, where the task carries ws:// and wss://):
/// - `CHANNEL_WSS_URL`: a TLS endpoint in front of a channel fixture whose certificate the process trusts
///   (`SSL_CERT_FILE`), e.g. wss://localhost:8443
/// - `CHANNEL_WSS_MISMATCH_URL`: the same endpoint by a name its certificate doesn't have (wss://127.0.0.1:8443)
/// - `CHANNEL_WS_BAD_ACCEPT_URL`: a ws:// server answering the upgrade with a wrong Sec-WebSocket-Accept
///
/// `Tests/Fixture/ws-proxy.py` makes them in front of a channel fixture on 2061 (HubServer's `channel-fixture 2061`):
/// `ws-proxy.py 8443 2061 --tls cert.pem key.pem` (a self-signed certificate for DNS:localhost) and
/// `ws-proxy.py 8444 2061 --bad-accept`; then `SSL_CERT_FILE=cert.pem CHANNEL_WSS_URL=wss://localhost:8443
/// CHANNEL_WSS_MISMATCH_URL=wss://127.0.0.1:8443 CHANNEL_WS_BAD_ACCEPT_URL=ws://127.0.0.1:8444 swift test --filter
/// SocketWebSocketTests`.
@MainActor
struct SocketWebSocketTests {
  nonisolated static func url(_ name: String) -> URL? {
    ProcessInfo.processInfo.environment[name].flatMap(URL.init(string:))
  }

  @Test("Sec-WebSocket-Accept of RFC 6455's example key")
  func acceptValue() {
    #expect(SocketWebSocketTask.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    #expect(SocketWebSocketTask.sha1([]).map { String(format: "%02x", $0) }.joined() == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  }

  /// The first message or the failure of a task to `url`.
  nonisolated func firstResult(_ url: URL) async -> Result<URLSessionWebSocketTask.Message, any Error> {
    let task = SocketWebSocketTask(request: URLRequest(url: url), maximumMessageSize: 1 << 20)
    task.resume()
    return await withCheckedContinuation { continuation in
      task.receive { continuation.resume(returning: $0) }
    }
  }

  @Test("wss:// carries the channel", .enabled(if: url("CHANNEL_WSS_URL") != nil && SocketWebSocketTask.isNeeded(for: URL(string: "wss://x")!)))
  func secureChannel() async throws {
    let client = Channel<Void>().connect(Self.url("CHANNEL_WSS_URL")!)
    let hello: String = try await client.send("hello")
    #expect(hello == "world")
    let random = Double.random(in: 0..<1)
    let echo: Double = try await client.send("echo", random)
    #expect(echo == random)
  }

  @Test("a certificate for another name fails the connection", .enabled(if: url("CHANNEL_WSS_MISMATCH_URL") != nil))
  func nameMismatch() async {
    let result = await firstResult(Self.url("CHANNEL_WSS_MISMATCH_URL")!)
    guard case .failure(let error) = result else {
      Issue.record("connected")
      return
    }
    #expect("\(error)".contains("isn't trusted"))
  }

  @Test("a wrong Sec-WebSocket-Accept fails the connection", .enabled(if: url("CHANNEL_WS_BAD_ACCEPT_URL") != nil))
  func wrongAccept() async {
    let result = await firstResult(Self.url("CHANNEL_WS_BAD_ACCEPT_URL")!)
    guard case .failure(let error) = result else {
      Issue.record("connected")
      return
    }
    #expect("\(error)".contains("Sec-WebSocket-Accept"))
  }
}
