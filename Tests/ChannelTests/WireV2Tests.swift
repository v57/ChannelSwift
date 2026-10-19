import Foundation
import Testing
@testable import Channel

// Channel wire v2 cases (PROTOCOL.md §7) against the fixture on `CHANNEL_FIXTURE_PORT` (default 2051).
// Serialized because `v2/drop` uses a counter shared by every connection.

private struct Remaining: Decodable { var remaining: Int }
private struct RetryAfter: Decodable { var retryAfter: Double }
private struct Room: Encodable, Sendable { var room: String }
private struct Publish<Body: Encodable & Sendable>: Encodable, Sendable { var room: String; var body: Body }
private struct Name: Encodable, Sendable { var name: String }

@MainActor
private func reconnect(_ client: ClientSender<Void>) async {
  client.ws.dropConnection()
  #expect(client.connectionState != .connected)
  #expect(await waitUntil { client.connectionState == .connected })
}

@Suite("wire v2", .serialized)
@MainActor
struct WireV2Tests {
  // 1
  @Test("structured errors carry message, code and info")
  func structuredError() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let error = await channelError { try await client.send("v2/error") }
    #expect(error?.text == "banned")
    #expect(error?.description == "banned")
    #expect(error?.code == 403)
    #expect(error?.code == .int(403))
    #expect(try error?.info?.decode(Remaining.self).remaining == 5)

    let coded = await channelError { try await client.send("v2/error/code") }
    #expect(coded?.text == "slow down")
    #expect(coded?.code == .rateLimited)
    #expect(try coded?.info?.decode(RetryAfter.self).retryAfter == 1)
  }

  // 2
  @Test("v1 string errors and not_found")
  func v1Errors() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let error = await channelError { try await client.send("auth/name") }
    #expect(error?.text == "unauthorized")
    #expect(error?.code == nil)
    #expect(error?.info == nil)
    #expect("\(error!)".contains("unauthorized"))

    let missing = await channelError { try await client.send("v2/missing") }
    #expect(missing?.text == "api not found")
    #expect(missing?.code == .notFound)

    let missingSub = await channelError { _ = try await client.subscribe("v2/missing") { _ in } }
    #expect(missingSub?.code == .notFound)
  }

  // 3
  @Test("one-shot sub delivers once and isn't replayed")
  func oneShot() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let events = Events()
    let token = try await client.subscribe("v2/once", event: events.handler)
    #expect(events.values == [.string("once")])
    #expect(client.ws.pendingCount == 0)
    await reconnect(client)
    let _: String = try await client.send("hello")
    await sleep(seconds: 0.05)
    #expect(events.values == [.string("once")])
    token.cancel()
  }

  // 4
  @Test("room sub: snapshot, events, falsy events, unsubscribe")
  func room() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let room = UUID().uuidString
    let events = Events()
    let token = try await client.subscribe("v2/room", Room(room: room), event: events.handler)
    #expect(events.values == [.string("joined")])

    try await client.send("v2/publish", Publish(room: room, body: "hi"))
    try await client.send("v2/publish", Publish(room: room, body: 0))
    try await client.send("v2/publish", Publish(room: room, body: false))
    try await client.send("v2/publish", Publish(room: room, body: ""))
    #expect(await waitUntil { events.values.count == 5 })
    #expect(events.values == [.string("joined"), .string("hi"), .int(0), .bool(false), .string("")])

    token.cancel()
    #expect(client.ws.pendingCount == 0)
    try await client.send("v2/publish", Publish(room: room, body: 1))
    await sleep(seconds: 0.05)
    #expect(events.values.count == 5)

    // A cancelled sub isn't sent again after a reconnect
    await reconnect(client)
    try await client.send("v2/publish", Publish(room: room, body: 2))
    await sleep(seconds: 0.05)
    #expect(events.values.count == 5)
  }

  // 5
  @Test("an active sub is resubscribed after a reconnect with a fresh snapshot")
  func resubscribe() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let room = UUID().uuidString
    let events = Events()
    let token = try await client.subscribe("v2/room", Room(room: room), event: events.handler)
    #expect(events.values == [.string("joined")])
    await reconnect(client)
    #expect(await waitUntil { events.values.count == 2 })
    #expect(events.values == [.string("joined"), .string("joined")])
    try await client.send("v2/publish", Publish(room: room, body: 7))
    #expect(await waitUntil { events.values.count == 3 })
    #expect(events.values.last == .int(7))
    token.cancel()
  }

  @Test("private sub refuses without auth, then delivers the name")
  func privateSub() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let events = Events()
    let error = await channelError { _ = try await client.subscribe("v2/private", event: events.handler) }
    #expect(error?.text == "unauthorized")
    #expect(error?.code == 401)
    #expect(client.ws.pendingCount == 0)
    let _: String = try await client.send("auth", Name(name: "tester"))
    let token = try await client.subscribe("v2/private", event: events.handler)
    #expect(events.values == [.string("tester")])
    token.cancel()
  }

  // 6
  @Test("timeout on v2/never")
  func timeout() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let started = Date()
    let error = await channelError { try await client.send("v2/never", options: SendOptions(timeout: 0.2)) }
    #expect(error?.code == .timeout)
    #expect(Date().timeIntervalSince(started) < 1)
    #expect(client.ws.pendingCount == 0)
    // The connection is still usable
    let hello: String = try await client.send("hello")
    #expect(hello == "world")
  }

  @Test("requestTimeout is the default for every call")
  func requestTimeout() async throws {
    let client = await Fixture.client(ClientOptions(requestTimeout: 0.2))
    defer { client.stop() }
    let error = await channelError { try await client.send("v2/never") }
    #expect(error?.code == .timeout)
    let subError = await channelError { _ = try await client.subscribe("v2/room", Room(room: "x"), options: SendOptions(timeout: 0.000_001)) { _ in } }
    #expect(subError?.code == .timeout)
    #expect(client.ws.pendingCount == 0)
  }

  // 7
  @Test("replay: false fails with disconnected; default replay sends the request again")
  func replay() async throws {
    let observer = await Fixture.client()
    defer { observer.stop() }
    try await observer.send("v2/drops/reset")

    let client = await Fixture.client()
    let error = await channelError { try await client.send("v2/drop", options: SendOptions(replay: false)) }
    #expect(error?.code == .disconnected)
    let drops: Int = try await observer.send("v2/drops")
    #expect(drops == 1)

    // With the default, the request goes out again after every reconnect, so the counter keeps climbing.
    // Stop after 2 more drops.
    let call = Task { @MainActor in
      try await client.send("v2/drop")
    }
    var count = 1
    for _ in 0..<200 where count < 3 {
      await sleep(seconds: 0.02)
      count = try await observer.send("v2/drops")
    }
    #expect(count >= 3)
    client.stop()
    let stopped = await channelError { try await call.value }
    #expect(stopped?.code == .disconnected)
  }

  // 8
  @Test("rate limit: the 3rd call fails with rate_limited")
  func rateLimit() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    try await client.send("v2/rate")
    try await client.send("v2/rate")
    let error = await channelError { try await client.send("v2/rate") }
    #expect(error?.code == .rateLimited)
    let retryAfter = try error?.info?.decode(RetryAfter.self).retryAfter ?? 0
    #expect(retryAfter > 0)
  }

  // 9
  @Test("async headers are evaluated before every connection")
  func headers() async throws {
    final class Counter { var value = 0 }
    let counter = Counter()
    let client = await Fixture.client(ClientOptions(headers: {
      await Task.yield()
      counter.value += 1
      return ["x-attempt": "\(counter.value)"]
    }))
    defer { client.stop() }
    let first: [String: String] = try await client.send("v2/headers")
    #expect(first["x-attempt"] == "1")
    await reconnect(client)
    let second: [String: String] = try await client.send("v2/headers")
    #expect(second["x-attempt"] == "2")
  }

  @Test("sync headers still work")
  func syncHeaders() async throws {
    let client = await Fixture.client(ClientOptions(headers: { ["x-sync": "yes"] }))
    defer { client.stop() }
    let headers: [String: String] = try await client.send("v2/headers")
    #expect(headers["x-sync"] == "yes")
  }

  // 10
  @Test("stop() fails pending calls with disconnected")
  func stop() async throws {
    let client = await Fixture.client()
    let written = Task { @MainActor in try await client.send("v2/never") }
    #expect(await waitUntil { client.ws.pendingCount == 1 })
    client.stop()
    #expect(await channelError { try await written.value }?.code == .disconnected)
    #expect(client.ws.pendingCount == 0)
    #expect(client.connectionState == .disconnected)

    // A call made after stop() waits until start()
    let offline = Task { @MainActor in try await client.send("hello") as String }
    await sleep(seconds: 0.2)
    #expect(client.ws.pendingCount == 1)
    client.ws.start()
    #expect(try await offline.value == "world")
    client.stop()
  }

  @Test("a reply that doesn't decode fails only that call")
  func decoding() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    let error = await channelError { let _: Int = try await client.send("hello") }
    #expect(error?.code == .decoding)
    let hello: String = try await client.send("hello")
    #expect(hello == "world")
  }

  @Test("invalid JSON closes and reconnects, replayable calls survive")
  func invalidJSON() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    var seen = [ConnectionState]()
    let observer = client.onStateChange { seen.append($0) }
    let call = Task { @MainActor in try await client.send("v2/never") }
    #expect(await waitUntil { client.ws.pendingCount == 1 })
    client.ws.received(text: "{not json", from: client.ws.currentTask)
    #expect(await waitUntil { seen.contains(.disconnected) })
    #expect(await waitUntil { client.connectionState == .connected })
    #expect(seen == [.disconnected, .connecting, .connected])
    #expect(client.ws.pendingCount == 1)
    // Valid JSON that isn't a message is ignored
    client.ws.received(text: "42", from: client.ws.currentTask)
    await sleep(seconds: 0.05)
    #expect(client.connectionState == .connected)
    client.stop()
    #expect(await channelError { try await call.value }?.code == .disconnected)
    observer.cancel()
  }

  @Test("8 MiB messages go through")
  func largeMessage() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    #expect(client.ws.maximumMessageSize == 16 << 20)
    let text = String(repeating: "a", count: 8 << 20)
    let echo: String = try await client.send("echo", text)
    #expect(echo.count == text.count)
  }

  @Test("connection state observers")
  func states() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    var iterator = client.states.makeAsyncIterator()
    #expect(await iterator.next() == .connected)
    var callback = [ConnectionState]()
    var legacy = [Bool]()
    client.ws.isConnectedChanged = { legacy.append($0) }
    let observer = client.onStateChange { callback.append($0) }
    client.ws.dropConnection()
    #expect(await iterator.next() == .disconnected)
    #expect(await iterator.next() == .connecting)
    #expect(await iterator.next() == .connected)
    #expect(callback == [.disconnected, .connecting, .connected])
    #expect(legacy == [false, true])
    observer.cancel()
  }

  @Test("reconnectNow skips the backoff")
  func reconnectNow() async throws {
    let client = await Fixture.client()
    defer { client.stop() }
    client.ws.dropConnection()
    client.reconnectNow()
    #expect(client.connectionState == .connecting)
    #expect(await waitUntil(0.5) { client.connectionState == .connected })
    // On an open connection it only checks liveness with a ping
    client.reconnectNow()
    await sleep(seconds: 0.1)
    #expect(client.connectionState == .connected)
  }

  @Test("pings keep the connection open")
  func ping() async throws {
    let client = await Fixture.client(ClientOptions(pingInterval: 0.05))
    defer { client.stop() }
    var seen = [ConnectionState]()
    let observer = client.onStateChange { seen.append($0) }
    await sleep(seconds: 0.4)
    #expect(seen.isEmpty)
    #expect(client.connectionState == .connected)
    observer.cancel()
  }

  @Test("no pong in time reconnects")
  func pongTimeout() async throws {
    let client = await Fixture.client(ClientOptions(pingInterval: 0.05))
    defer { client.stop() }
    client.ws.pongTimeout = 0
    var seen = [ConnectionState]()
    let observer = client.onStateChange { seen.append($0) }
    #expect(await waitUntil { seen.contains(.disconnected) })
    observer.cancel()
  }
}
