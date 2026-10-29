import Foundation
import Testing
@testable import Channel

// Channel over QUIC against the TypeScript reference's fixture (channel/tests/server.ts, run by
// Tests/Fixture/quic-server.ts), which serves its routes over QUIC on UDP next to WebSocket on TCP: on 2053 with the
// reference's test certificate, which only pinning accepts here, and on 2054 with one made for this run.

private let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()
/// The TypeScript reference next to this checkout, as in the Hub folder
private let reference = checkout.deletingLastPathComponent().appendingPathComponent("channel")
private let referenceExists = FileManager.default.fileExists(atPath: reference.appendingPathComponent("quic.ts").path)
/// Its test certificate: localhost, 127.0.0.1 and ::1
private let fingerprint = "DD:D2:37:00:BD:8A:BD:29:14:15:D8:65:84:BE:C2:80:10:FF:21:DA:A1:C5:9D:B3:4A:7F:36:63:EF:4B:55:9B"

private struct Name: Codable, Sendable { var name: String }
private struct Echo: Codable, Sendable, Equatable { var list: [Int]; var text: String }

enum QUICFixture {
  /// The reference's certificate (100 years, no extended key usage)
  static let referencePort = 2053
  /// The certificate made for this run
  static let port = 2054
  @MainActor private static var started: Task<Void, Never>?
  private static let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("channel-quic-\(ProcessInfo.processInfo.processIdentifier)")

  static var referenceCert: Data {
    (try? Data(contentsOf: reference.appendingPathComponent("tests/quic/cert.pem"))) ?? Data()
  }
  static var cert: Data {
    _ = generated
    return (try? Data(contentsOf: directory.appendingPathComponent("cert.pem"))) ?? Data()
  }

  /// A self-signed certificate Apple's TLS accepts as an anchor: 30 days, serverAuth, the loopback addresses
  private static let generated: Bool = {
    #if os(macOS)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj", "/CN=localhost",
                         "-keyout", directory.appendingPathComponent("key.pem").path,
                         "-out", directory.appendingPathComponent("cert.pem").path,
                         "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1",
                         "-addext", "extendedKeyUsage=serverAuth"]
    openssl.standardError = FileHandle.nullDevice
    try? openssl.run()
    openssl.waitUntilExit()
    #endif
    return true
  }()

  @MainActor static func start() async {
    if let started { return await started.value }
    let task = Task { @MainActor in
      #if os(macOS)
      _ = generated
      await runBun(checkout.appendingPathComponent("Tests/Fixture/quic-server.ts"), environment: [
        "CHANNEL_TEST_PORT": "\(referencePort)",
        "QUIC_KEY": directory.appendingPathComponent("key.pem").path,
        "QUIC_CERT": directory.appendingPathComponent("cert.pem").path,
      ])
      #endif
    }
    started = task
    await task.value
  }

  @MainActor static func client(_ quic: QUICOptions, port: Int = port, headers: [String: String] = [:]) async -> ClientSender<Void> {
    await start()
    var options = ClientOptions<Void>(requestTimeout: 5, quic: quic)
    if !headers.isEmpty { options.headers = { @MainActor @Sendable in headers } }
    return channel.connect(URL(string: "quic://127.0.0.1:\(port)")!, options: options)
  }
}

@Test("QUIC frames: varint lengths, keepalives, limit")
func quicFrames() throws {
  for size in [0, 1, 63, 64, 16383, 16384, 70000] {
    let payload = Data(repeating: 0x78, count: size)
    let frame = QUICFrame.encode(payload)
    let header = size < 64 ? 1 : size < 16384 ? 2 : 4
    #expect(frame.count - size == header)
    var buffer = Data([0]) + frame + QUICFrame.encode(Data("next".utf8))
    // Split mid-frame: the rest stays in the buffer
    var head = buffer.prefix(buffer.count - 2)
    let first = try QUICFrame.decode(&head, maximum: 1 << 20)
    #expect(first == (size > 0 ? [payload] : []))
    buffer = head + buffer.suffix(2)
    #expect(try QUICFrame.decode(&buffer, maximum: 1 << 20) == [Data("next".utf8)])
    #expect(buffer.isEmpty)
  }
  var eightBytes = Data([0xc0, 0, 0, 0, 0, 0, 0, 2]) + Data("ok".utf8)
  #expect(try QUICFrame.decode(&eightBytes, maximum: 10) == [Data("ok".utf8)])
  var big = QUICFrame.encode(Data(count: 11))
  #expect(throws: QUICFrame.TooLarge.self) { try QUICFrame.decode(&big, maximum: 10) }
}

#if canImport(Network)
@Suite("QUIC against the TypeScript reference", .serialized, .enabled(if: referenceExists))
@MainActor
struct QUICTests {
  @Test("requests, hello headers, state, mirror and streams")
  func calls() async throws {
    let client = await QUICFixture.client(QUICOptions(ca: QUICFixture.cert), headers: ["X-Port": "swift"])
    defer { client.stop() }
    #expect(await waitUntil(5) { client.connectionState == .connected })

    let hello: String = try await client.send("hello")
    #expect(hello == "world")
    let body = Echo(list: [1, 2, 3], text: String(repeating: "é", count: 20000))
    let echo: Echo = try await client.send("echo", body)
    #expect(echo == body)
    let headers: [String: String] = try await client.send("v2/headers")
    #expect(headers["x-port"] == "swift")
    let name: String = try await client.send("auth", Name(name: "quic"))
    #expect(name == "quic")
    let stored: String = try await client.send("auth/name")
    #expect(stored == "quic")
    let mirror: String = try await client.send("mirror")
    #expect(mirror == "client world")
    var values = [Int]()
    for try await value in client.values("mirror/stream", as: Int.self) { values.append(value) }
    #expect(values == [0, 1, 2])
  }

  @Test("reconnects after a drop, with a new connection state")
  func reconnect() async throws {
    let client = await QUICFixture.client(QUICOptions(ca: QUICFixture.cert))
    defer { client.stop() }
    #expect(await waitUntil(5) { client.connectionState == .connected })
    let _: String = try await client.send("auth", Name(name: "before"))
    client.ws.dropConnection()
    #expect(await waitUntil(5) { client.connectionState == .connected })
    let hello: String = try await client.send("hello")
    #expect(hello == "world")
    await #expect(throws: (any Error).self) { let _: String = try await client.send("auth/name") }
  }

  @Test("a pinned fingerprint replaces verification")
  func pinned() async throws {
    let client = await QUICFixture.client(QUICOptions(fingerprint: fingerprint.lowercased()), port: QUICFixture.referencePort)
    defer { client.stop() }
    #expect(await waitUntil(5) { client.connectionState == .connected })
    let hello: String = try await client.send("hello")
    #expect(hello == "world")
  }

  @Test("the server name can be overridden")
  func serverName() async throws {
    let client = await QUICFixture.client(QUICOptions(ca: QUICFixture.cert, serverName: "localhost"))
    defer { client.stop() }
    #expect(await waitUntil(5) { client.connectionState == .connected })
  }

  @Test("an untrusted certificate doesn't connect", arguments: [
    QUICOptions(),
    QUICOptions(fingerprint: String(repeating: "00", count: 32)),
    QUICOptions(serverName: "example.com"),
    QUICOptions(ca: QUICFixture.referenceCert),
    QUICOptions(fingerprint: "nope"),
  ])
  func untrusted(_ options: QUICOptions) async throws {
    var options = options
    if options.serverName != nil { options.ca = QUICFixture.cert }
    let client = await QUICFixture.client(options)
    defer { client.stop() }
    #expect(await waitUntil(1) { client.connectionState == .connected } == false)
  }

  @Test("Apple's TLS refuses the reference's 100-year certificate as an anchor")
  func longLivedAnchor() async throws {
    let client = await QUICFixture.client(QUICOptions(ca: QUICFixture.referenceCert), port: QUICFixture.referencePort)
    defer { client.stop() }
    #expect(await waitUntil(1) { client.connectionState == .connected } == false)
  }
}
#endif
