import Foundation
import Testing
@testable import Channel

/// Records what the channel sends and lets tests feed responses, without a socket
@MainActor
final class FakeConnection: ConnectionInterface {
  var isConnected = true
  var requestTimeout: TimeInterval?
  /// JSON of every request, in order
  var requests = [String]()
  /// JSON of every notification (`cancel`, `unsub`)
  var notified = [String]()
  var pending = [Int: RequestOptions]()
  private var nextId = 0
  private var topics = [String: [Int: @MainActor (AnyBody) -> Void]]()
  private var nextTopicId = 0

  func send<Body: Encodable>(_ body: Body) -> Int {
    send(body, options: RequestOptions())
  }
  func send<Body: Encodable>(_ body: Body, options: RequestOptions) -> Int {
    let id = nextId
    nextId += 1
    requests.append(json(body))
    pending[id] = options
    return id
  }
  func sent(_ id: Int) {
    pending[id] = nil
  }
  func cancel(_ id: Int) -> Bool {
    pending.removeValue(forKey: id) != nil && !isConnected
  }
  func notify<Body: Encodable>(_ body: Body) {
    notified.append(json(body))
  }
  func addTopic(topic: String, event: @escaping @MainActor (AnyBody) -> Void) -> @Sendable @MainActor () -> Bool {
    let id = nextTopicId
    nextTopicId += 1
    topics[topic, default: [:]][id] = event
    return { [weak self] in
      guard let self else { return false }
      self.topics[topic]?[id] = nil
      guard self.topics[topic]?.isEmpty == true else { return false }
      self.topics[topic] = nil
      return true
    }
  }
  func event(_ topic: String, _ body: AnyBody) {
    topics[topic]?.values.forEach { $0(body) }
  }
  var topicCount: Int { topics.count }
  /// Fails every pending call like `WebSocketClient.stop()`
  func stop() {
    let all = pending.sorted { $0.key < $1.key }
    pending.removeAll()
    for (_, options) in all {
      options.fail?(.disconnected)
    }
  }
  /// Fails the pending calls that can't be replayed, like a dropped connection
  func drop() {
    for (id, options) in pending.sorted(by: { $0.key < $1.key }) where !options.replay {
      pending[id] = nil
      options.fail?(.disconnected)
    }
  }
  private func json<Body: Encodable>(_ body: Body) -> String {
    String(decoding: try! JSONEncoder.iso8601.encode(AnyEncodable(body: body)), as: UTF8.self)
  }
}

@MainActor
private struct FakeController: Controller {
  let connection: FakeConnection
  let sender: any Sender
  var state: Void { () }
  func respond(_ response: Encodable & Sendable) { }
  func subscribe(_ topic: String) { }
  func unsubscribe(_ topic: String) { }
  func event(_ topic: String, _ event: AnyBody) {
    connection.event(topic, event)
  }
}

@MainActor
private final class Harness {
  let channel = Channel<Void>()
  let connection = FakeConnection()
  lazy var sender = ChannelSender(ch: channel, connection: connection)
  /// Feeds one or more messages to the channel, as JSON text
  func receive(_ text: String) {
    let messages = try! JSONDecoder.iso8601.decode(DecodableArray<ReceivedResponse>.self, from: Data(text.utf8)).array
    channel.receive(messages, controller: FakeController(connection: connection, sender: sender))
  }
  /// Waits until the channel has sent `count` requests
  func requests(_ count: Int) async {
    #expect(await waitUntil { self.connection.requests.count >= count })
  }
}

@Suite("unit")
@MainActor
struct UnitTests {
  @Test("error code and info decode, error objects don't drop the reply")
  func errorDecoding() async throws {
    let h = Harness()
    let int = Task { try await h.sender.send("a") }
    let string = Task { try await h.sender.send("b") }
    let object = Task { try await h.sender.send("c") }
    await h.requests(3)
    h.receive(#"[{"id":0,"error":"banned","code":403,"info":{"remaining":5}},{"id":1,"error":"slow","code":"rate_limited"},{"id":2,"error":{"message":"nope"}}]"#)
    let a = await channelError { try await int.value }
    #expect(a?.code == 403)
    struct Remaining: Decodable { var remaining: Int }
    #expect(try a?.info?.decode(Remaining.self).remaining == 5)
    #expect(await channelError { try await string.value }?.code == .rateLimited)
    let c = await channelError { try await object.value }
    #expect(c?.text == "nope")
    #expect(c?.code == nil)
  }

  @Test("a reply that doesn't decode fails with decoding")
  func decoding() async throws {
    let h = Harness()
    let call = Task { let _: Int = try await h.sender.send("a"); }
    await h.requests(1)
    h.receive(#"{"id":0,"body":"text"}"#)
    #expect(await channelError { try await call.value }?.code == .decoding)
    #expect(h.connection.pending.isEmpty)
  }

  @Test("timeout fails the call and sends cancel when it was written")
  func timeout() async throws {
    let h = Harness()
    let error = await channelError { try await h.sender.send("never", options: SendOptions(timeout: 0.05)) }
    #expect(error?.code == .timeout)
    #expect(error?.text == "timeout")
    #expect(h.connection.notified == [#"{"cancel":0}"#])
    #expect(h.connection.pending.isEmpty)
    #expect(h.channel.requests.isEmpty)
    // A late reply is ignored
    h.receive(#"{"id":0,"body":1}"#)
  }

  @Test("timeout while offline doesn't send cancel")
  func offlineTimeout() async throws {
    let h = Harness()
    h.connection.isConnected = false
    h.connection.requestTimeout = 0.05
    #expect(await channelError { try await h.sender.send("never") }?.code == .timeout)
    #expect(h.connection.notified.isEmpty)
    #expect(h.connection.pending.isEmpty)
  }

  @Test("replay option reaches the connection")
  func replayOption() async throws {
    let h = Harness()
    let call = Task { try await h.sender.send("drop", options: SendOptions(replay: false)) }
    let replayed = Task { try await h.sender.send("drop") }
    await h.requests(2)
    #expect(h.connection.pending[0]?.replay == false)
    #expect(h.connection.pending[1]?.replay == true)
    h.connection.drop()
    #expect(await channelError { try await call.value }?.code == .disconnected)
    #expect(h.connection.pending.count == 1)
    h.connection.stop()
    #expect(await channelError { try await replayed.value }?.code == .disconnected)
    #expect(h.channel.requests.isEmpty)
  }

  @Test("subscription: snapshot first, falsy events, cancel removes it from the replay set")
  func subscription() async throws {
    let h = Harness()
    let events = Events()
    let sub = Task { try await h.sender.subscribe("room", "a", event: events.handler) }
    await h.requests(1)
    #expect(h.connection.requests.first?.contains(#""sub":"room""#) == true)
    h.receive(#"{"id":0,"topic":"room/a","body":"snapshot"}"#)
    let token = try await sub.value
    #expect(events.values == [.string("snapshot")])
    #expect(token.topic == "room/a")
    #expect(token.isSubscribed)
    h.receive(#"[{"topic":"room/a","body":0},{"topic":"room/a","body":false},{"topic":"room/a","body":""},{"topic":"room/a","body":null},{"topic":"room/a"}]"#)
    #expect(events.values == [.string("snapshot"), .int(0), .bool(false), .string(""), .null])
    // Still in the replay set while active; a resubscribe delivers a fresh snapshot
    #expect(h.connection.pending.count == 1)
    h.receive(#"{"id":0,"topic":"room/a","body":"again"}"#)
    #expect(events.values.last == .string("again"))

    token.cancel()
    #expect(!token.isSubscribed)
    #expect(h.connection.pending.isEmpty)
    #expect(h.channel.requests.isEmpty)
    #expect(h.connection.notified == [#"{"unsub":"room\/a"}"#])
    h.receive(#"{"topic":"room/a","body":1}"#)
    #expect(events.values.count == 6)
    token.cancel()
    #expect(h.connection.notified.count == 1)
  }

  @Test("subscription without a snapshot body delivers nothing first")
  func noSnapshot() async throws {
    let h = Harness()
    let events = Events()
    let sub = Task { try await h.sender.subscribe("room", event: events.handler) }
    await h.requests(1)
    h.receive(#"{"id":0,"topic":"t"}"#)
    let token = try await sub.value
    #expect(events.values.isEmpty)
    token.cancel()
  }

  @Test("one-shot sub: one delivery, never replayed")
  func oneShot() async throws {
    let h = Harness()
    let events = Events()
    let sub = Task { try await h.sender.subscribe("once", event: events.handler) }
    await h.requests(1)
    h.receive(#"{"id":0,"body":"once"}"#)
    let token = try await sub.value
    #expect(events.values == [.string("once")])
    #expect(token.topic == nil)
    #expect(!token.isSubscribed)
    #expect(h.connection.pending.isEmpty)
    #expect(h.connection.topicCount == 0)
    h.receive(#"{"id":0,"body":"once"}"#)
    #expect(events.values.count == 1)
    token.cancel()
    #expect(h.connection.notified.isEmpty)
  }

  @Test("a resubscribe that is refused ends the subscription")
  func refusedResubscribe() async throws {
    let h = Harness()
    let events = Events()
    let sub = Task { try await h.sender.subscribe("private", event: events.handler) }
    await h.requests(1)
    h.receive(#"{"id":0,"topic":"private/a","body":"a"}"#)
    let token = try await sub.value
    h.receive(#"{"id":0,"error":"unauthorized","code":401}"#)
    #expect(h.connection.pending.isEmpty)
    #expect(h.channel.requests.isEmpty)
    #expect(h.connection.topicCount == 0)
    #expect(!token.isSubscribed)
    #expect(h.connection.notified == [#"{"unsub":"private\/a"}"#])
    h.receive(#"{"topic":"private/a","body":"b"}"#)
    #expect(events.values == [.string("a")])
    token.cancel()
    #expect(h.connection.notified.count == 1)
  }
  
  @Test("replay: false ends an active subscription when the connection drops")
  func subscriptionNoReplay() async throws {
    let h = Harness()
    let events = Events()
    let sub = Task { try await h.sender.subscribe("room", options: SendOptions(replay: false), event: events.handler) }
    await h.requests(1)
    #expect(h.connection.pending[0]?.replay == false)
    h.receive(#"{"id":0,"topic":"room","body":1}"#)
    let token = try await sub.value
    h.connection.drop()
    #expect(h.channel.requests.isEmpty)
    #expect(h.connection.topicCount == 0)
    token.cancel()
  }

  @Test("a resubscribe with a new topic moves the handler")
  func topicChange() async throws {
    let h = Harness()
    let events = Events()
    let sub = Task { try await h.sender.subscribe("me", event: events.handler) }
    await h.requests(1)
    h.receive(#"{"id":0,"topic":"user/1","body":1}"#)
    let token = try await sub.value
    h.receive(#"{"id":0,"topic":"user/2","body":2}"#)
    h.receive(#"[{"topic":"user/1","body":3},{"topic":"user/2","body":4}]"#)
    #expect(events.values == [.int(1), .int(2), .int(4)])
    #expect(token.topic == "user/2")
    #expect(h.connection.topicCount == 1)
    token.cancel()
  }

  @Test("subscription errors and timeouts")
  func subscriptionFailures() async throws {
    let h = Harness()
    let refused = Task { try await h.sender.subscribe("private") { _ in } }
    await h.requests(1)
    h.receive(#"{"id":0,"error":"unauthorized","code":401}"#)
    #expect(await channelError { _ = try await refused.value }?.code == 401)
    #expect(h.connection.pending.isEmpty)

    let error = await channelError { _ = try await h.sender.subscribe("never", options: SendOptions(timeout: 0.05)) { _ in } }
    #expect(error?.code == .timeout)
    #expect(h.connection.notified == [#"{"cancel":1}"#])
    #expect(h.connection.pending.isEmpty)
    #expect(h.channel.requests.isEmpty)

    let stopped = Task { try await h.sender.subscribe("never") { _ in } }
    await h.requests(3)
    h.connection.stop()
    #expect(await channelError { _ = try await stopped.value }?.code == .disconnected)
  }

  @Test("streams fail with disconnected on stop")
  func streamStop() async throws {
    let h = Harness()
    let stream = Task { @MainActor in
      var values = [Int]()
      for try await value in h.sender.values("numbers", as: Int.self) {
        values.append(value)
      }
      return values
    }
    await h.requests(1)
    h.receive(#"{"id":0,"body":1}"#)
    h.connection.stop()
    #expect(await channelError { _ = try await stream.value }?.code == .disconnected)
  }

  @Test("stream errors carry the code and free the request")
  func streamError() async throws {
    let h = Harness()
    let stream = Task { @MainActor in
      for try await _ in h.sender.values("numbers", as: Int.self) { }
    }
    await h.requests(1)
    h.receive(#"{"id":0,"error":"nope","code":"x"}"#)
    #expect(await channelError { try await stream.value }?.code == "x")
    #expect(h.channel.requests.isEmpty)
  }

  @Test("pending queue replays in order and fails written non-replayable requests on a drop")
  func pendingQueue() {
    var queue = PendingQueue()
    func entry(_ name: String, replay: Bool = true, written: Bool) -> PendingQueue.Entry {
      PendingQueue.Entry(body: AnyEncodable(body: name), replay: replay, written: written, fail: nil)
    }
    for id in [5, 1, 12, 3, 8] {
      queue.add(id, entry("\(id)", written: false))
    }
    let order = queue.flush().map { $0.body as! String }
    #expect(order == ["1", "3", "5", "8", "12"])

    queue = PendingQueue()
    queue.add(0, entry("written", replay: false, written: true))
    queue.add(1, entry("queued", replay: false, written: false))
    queue.add(2, entry("replay", written: true))
    let failed = queue.dropped().map { $0.body.body as! String }
    #expect(failed == ["written"])
    #expect(queue.count == 2)
    // After the drop nothing counts as written, so a second drop fails nothing
    #expect(queue.dropped().isEmpty)
    _ = queue.flush()
    #expect(queue.dropped().map { $0.body.body as! String } == ["queued"])
    #expect(queue.removeAll().map { $0.body.body as! String } == ["replay"])
  }

  @Test("reconnect backoff: 100 ms doubling to 5 s, randomized to 50-100%")
  func backoff() {
    #expect(WebSocketClient.reconnectDelay(attempts: 0, random: 1) == 0.1)
    #expect(WebSocketClient.reconnectDelay(attempts: 0, random: 0) == 0.05)
    #expect(abs(WebSocketClient.reconnectDelay(attempts: 3, random: 1) - 0.8) < 1e-9)
    #expect(WebSocketClient.reconnectDelay(attempts: 6, random: 1) == 5)
    #expect(WebSocketClient.reconnectDelay(attempts: 1000, random: 0) == 2.5)
  }

  @Test("ChannelError keeps text and description")
  func channelErrorText() {
    let error = ChannelError(text: "banned", code: 403)
    #expect(error.text == "banned")
    #expect(error.description == "banned")
    #expect("\(error)" == "banned")
    #expect(ChannelError.Code.string("timeout") == .timeout)
    #expect(ChannelError.Code.int(401).description == "401")
    let encoded = String(decoding: try! JSONEncoder().encode(Response(id: 1, error: ChannelError(text: "api not found", code: .notFound))), as: UTF8.self)
    #expect(encoded.contains(#""code":"not_found""#))
  }
}
