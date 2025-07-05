//
//  File.swift
//  ChannelSwift
//
//  Created by Dmitry Kozlov on 22/4/25.
//

import Foundation

// MARK: - Protocols

@MainActor
public protocol Controller: Sendable {
  associatedtype State
  func respond(_ response: Encodable & Sendable)
  func subscribe(_ topic: String)
  func unsubscribe(_ topic: String)
  func event(_ topic: String, _ event: AnyBody)
  var sender: any Sender { get }
  var state: State { get }
}
@MainActor
protocol StreamRequestProtocol: Sendable { }

@MainActor
public protocol ConnectionInterface: Sendable {
  @discardableResult
  func send<Body: Encodable>(_ body: Body) -> Int
  func sent(_ id: Int)
  func cancel(_ id: Int) -> Bool
  func notify<Body: Encodable>(_ body: Body)
  func addTopic(topic: String, event: @escaping @MainActor (AnyBody) -> Void) -> @Sendable @MainActor () -> Bool
  func stop()
}

// MARK: - Types
public typealias Function<State> = @Sendable (AnonymousBody<State>, String) async throws -> Encodable & Sendable
public typealias Stream<State> = @Sendable (AnonymousBody<State>, String) -> AsyncThrowingStream<Encodable & Sendable, Error>
public struct Request<Body: Encodable & Sendable>: Encodable, Sendable {
  public var id: Int
  public var path: String
  public var body: Body?
  public init(id: Int, path: String, body: Body? = nil) {
    self.id = id
    self.path = path
    self.body = body
  }
}
public struct AnonymousBody<State: Sendable>: Sendable {
  public var body: AnyBody
  public var sender: any Sender
  public var state: State
}
public struct Body<Body: Decodable & Sendable, State: Sendable>: Sendable {
  public var body: Body
  public var sender: any Sender
  public var state: State
}

public struct SubscriptionRequest<Body: Encodable & Sendable>: Encodable, Sendable {
  public var id: Int
  public var sub: String
  public var body: Body?
  
  public init(id: Int, sub: String, body: Body? = nil) {
    self.id = id
    self.sub = sub
    self.body = body
  }
}

public struct StreamRequest<Body: Encodable & Sendable>: Encodable, StreamRequestProtocol {
  public var id: Int
  public var stream: String
  public var body: Body?
  
  public init(id: Int, stream: String, body: Body? = nil) {
    self.id = id
    self.stream = stream
    self.body = body
  }
}

public struct Response: Encodable, Sendable {
  public var id: Int
  public var topic: String?
  public var body: (Encodable & Sendable)?
  public var error: ChannelError?
  public var done: Bool?
  
  public init(id: Int, topic: String? = nil, body: (Encodable & Sendable)? = nil, error: ChannelError? = nil, done: Bool? = nil) {
    self.id = id
    self.topic = topic
    self.body = body
    self.error = error
    self.done = done
  }
  enum CodingKeys: CodingKey {
    case id, topic, body, error, done
  }
  public func encode(to encoder: any Encoder) throws {
    var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.id, forKey: CodingKeys.id)
    try container.encodeIfPresent(self.topic, forKey: CodingKeys.topic)
    if let body {
      try container.encode(body, forKey: CodingKeys.body)
    }
    try container.encodeIfPresent(self.error, forKey: CodingKeys.error)
    try container.encodeIfPresent(self.done, forKey: CodingKeys.done)
  }
}
public struct ReceivedResponse: Decodable, @unchecked Sendable {
  var id: Int?
  var path: String?
  var stream: String?
  var cancel: Int?
  var sub: String?
  var unsub: String?
  var topic: String?
  var done: Bool?
  var error: String?
  let container: KeyedDecodingContainer<CodingKeys> /* @unchecked Sendable */
  var anyBody: AnyBody { AnyBody(container: container) }
  
  enum CodingKeys: CodingKey {
    case id, path, body, stream, cancel, sub, unsub, topic, done, error
  }
  
  public init(from decoder: any Decoder) throws {
    container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(Int.self, forKey: .id)
    self.path = try container.decodeIfPresent(String.self, forKey: .path)
    self.stream = try container.decodeIfPresent(String.self, forKey: .stream)
    self.cancel = try container.decodeIfPresent(Int.self, forKey: .cancel)
    self.sub = try container.decodeIfPresent(String.self, forKey: .sub)
    self.unsub = try container.decodeIfPresent(String.self, forKey: .unsub)
    self.topic = try container.decodeIfPresent(String.self, forKey: .topic)
    self.done = try container.decodeIfPresent(Bool.self, forKey: .done)
    self.error = try container.decodeIfPresent(String.self, forKey: .error)
  }
}
public struct ChannelError: Error, CustomStringConvertible, Codable, Sendable {
  public let text: String
  public var localizedDescription: String { text }
  public var description: String { text }
  public init(text: String) {
    self.text = text
  }
  public init?(optional: String?) {
    guard let optional else { return nil }
    self.text = optional
  }
  public init(error: Error) {
    if let error = error as? ChannelError {
      text = error.text
    } else {
      text = "internal error"
    }
  }
  public init(from decoder: any Decoder) throws {
    text = try decoder.singleValueContainer().decode(String.self)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.text)
  }
}

public struct PendingRequest: Sendable {
  public let request: Encodable & Sendable
  public let onResponse: @Sendable @MainActor (ReceivedResponse) -> Void
  public init(request: Encodable & Sendable, response: @escaping @Sendable @MainActor (ReceivedResponse) -> Void) {
    self.request = request
    self.onResponse = response
  }
}

// MARK: - Channel
@MainActor
public class Channel<State: Sendable>: @unchecked Sendable {
  private var id = 0
  public var requests: [Int: PendingRequest] = [:]
  public var postApi: [String: Function<State>] = [:]
  public var otherPostApi: [(path: (String) -> Bool, request: Function<State>)] = []
  public var streamApi: [String: Stream<State>] = [:]
  public var otherStreamApi: [(path: (String) -> Bool, request: Stream<State>)] = []
  public var _onDisconnect: ((State, any Sender) -> Void)?
  public var eventsApi: [String: SubscriptionProtocol]?
  private var streams: [Int: Task<Void, Error>] = [:]
  
  public init() { }
  
  public func post<Input: Decodable, Output: Encodable & Sendable>(_ path: String, request: @escaping ( @Sendable (Body<Input, State>) async throws -> Output)) -> Self {
    postApi[path] = { body, _ in
      try await request(Body(body: body.body.body(), sender: body.sender, state: body.state))
    }
    return self
  }
  public func post<Input: Decodable, Output: Encodable & Sendable>(_ path: String, request: @escaping (@Sendable (Input) async throws -> Output)) -> Self {
    postApi[path] = { body, _ in
      try await request(body.body.body())
    }
    return self
  }
  public func post<Input: Decodable>(_ path: String, request: @escaping (@Sendable (Input) async throws -> Void)) -> Self {
    postApi[path] = { body, _ in
      try await request(body.body.body())
      return EmptyCodable()
    }
    return self
  }
  public func post<Output: Encodable & Sendable>(_ path: String, request: @escaping (@Sendable () async throws -> Output)) -> Self {
    postApi[path] = { _, _ in
      try await request()
    }
    return self
  }
  public func post(_ path: String, request: @escaping (@Sendable () async throws -> Void)) -> Self {
    postApi[path] = { _, _ in
      try await request()
      return EmptyCodable()
    }
    return self
  }
  
  
  public func postOther(_ path: @escaping (String) -> Bool, request: @escaping Function<State>) -> Self {
    otherPostApi.append((path: path, request: request))
    return self
  }
  public func stream<Input: Decodable & Sendable>(_ path: String, request: @escaping @Sendable (Body<Input, State>, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    streamApi[path] = { body, _ in
      AsyncThrowingStream { continuation in
        Task {
          do {
            try await request(Body(body: body.body.body(), sender: body.sender, state: body.state), continuation)
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
      }
    }
    return self
  }
  public func stream<Input: Decodable & Sendable>(_ path: String, request: @escaping @Sendable (Input, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    stream(path) { body, continuation in
      try await request(body.body, continuation)
    }
  }
  public func stream(_ path: String, request: @escaping @Sendable (AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    streamApi[path] = { body, _ in
      AsyncThrowingStream { continuation in
        Task {
          do {
            try await request(continuation)
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
      }
    }
    return self
  }
  
  public func streamOther(_ path: @escaping (String) -> Bool, request: @escaping Stream<State>) -> Self {
    self.otherStreamApi.append((path: path, request: request))
    return self
  }
  
  public func onDisconnect(_ action: @escaping (State, any Sender) -> Void) -> Self {
    self._onDisconnect = action
    return self
  }
  
  public func makeRequest<Body: Encodable>(_ path: String, _ body: Body?, response: @escaping @Sendable @MainActor (ReceivedResponse) -> Void) -> Request<Body> {
    let id = self.id
    self.id += 1
    let pending = PendingRequest(request: Request(id: id, path: path, body: body), response: response)
    self.requests[id] = pending
    return Request(id: id, path: path, body: body)
  }
  
  public func makeStream<Body: Encodable>(_ stream: String, _ body: Body?, response: @escaping @Sendable @MainActor (ReceivedResponse) -> Void) -> StreamRequest<Body> {
    let id = self.id
    self.id += 1
    let pending = PendingRequest(request: StreamRequest(id: id, stream: stream, body: body), response: response)
    self.requests[id] = pending
    return StreamRequest(id: id, stream: stream, body: body)
  }
  
  public func makeSubscription<Body: Encodable>(_ sub: String, _ body: Body?, response: @escaping @Sendable @MainActor (ReceivedResponse) -> Void) -> SubscriptionRequest<Body> {
    let id = self.id
    self.id += 1
    let pending = PendingRequest(request: SubscriptionRequest(id: id, sub: sub, body: body), response: response)
    self.requests[id] = pending
    return SubscriptionRequest(id: id, sub: sub, body: body)
  }
  
  public func receive<C: Controller>(_ some: [ReceivedResponse], controller: C) where C.State == State {
    for a in some {
      self.receiveOne(a, controller: controller)
    }
  }
  
  private func receiveOne<C: Controller>(_ some: ReceivedResponse, controller: C) where C.State == State {
    if let path = some.path {
      let id = some.id
      let api: Function<State>? = self.postApi[path] ?? otherPostApi.first(where: { $0.path(path) })?.request
      do {
        guard let api else { throw ChannelError(text: "api not found") }
        let bodyParam = AnonymousBody(body: AnyBody(container: some.container), sender: controller.sender, state: controller.state)
        Task {
          do {
            let result = try await api(bodyParam, path)
            if let id {
              controller.respond(Response(id: id, body: result))
            }
          } catch {
            if let id {
              controller.respond(Response(id: id, error: ChannelError(error: error)))
            }
          }
        }
      } catch {
        if let id {
          controller.respond(Response(id: id, error: ChannelError(error: error)))
        }
      }
    } else if let path = some.stream {
      let id = some.id
      var api: Stream<State>? = self.streamApi[path]
      if api == nil {
        if let other = self.otherStreamApi.first(where: { $0.path(path) }) {
          api = other.request
        }
      }
      do {
        guard let api else { throw ChannelError(text: "api not found") }
        guard let id else { throw ChannelError(text: "stream requires id") }
        self.streamRequest(id, controller: controller, path: path, body: some.anyBody, stream: api)
      } catch {
        if let id {
          controller.respond(Response(id: id, error: ChannelError(error: error)))
        }
      }
    } else if let id = some.cancel {
      if let stream = streams[id] {
        stream.cancel()
        streams[id] = nil
      }
    } else if let sub = some.sub {
      let id = some.id
      guard let subscription = self.eventsApi?[sub] else {
        if let id {
          controller.respond(Response(id: id, error: ChannelError(text: "subscription not found")))
        }
        return
      }
      do {
        var topic = try subscription.getTopic(request: some.anyBody)
        if topic.count == 0 {
          topic = subscription.prefix
        } else {
          topic = subscription.prefix + "/" + topic
        }
        // Check if body is asynchronous is simulated by checking if the result is a function.
        let result = try subscription.getBody(request: some.anyBody)
        controller.subscribe(topic)
        if let reqId = id {
          controller.respond(Response(id: reqId, topic: topic, body: result))
        }
      } catch {
        if let id {
          controller.respond(Response(id: id, error: ChannelError(error: error)))
        }
      }
    } else if let unsub = some.unsub {
      controller.unsubscribe(unsub)
    } else if let topic = some.topic {
      if let id = some.id, let request = self.requests[id] {
        self.requests[id] = nil
        request.onResponse(some)
      }
      controller.event(topic, some.anyBody)
    } else if let id = some.id {
      guard let request = self.requests[id] else { return }
      if !((request.request is StreamRequestProtocol) && (some.done != true) ) {
        self.requests[id] = nil
      }
      request.onResponse(some)
    }
  }
  
  private func streamRequest<C: Controller>(_ id: Int, controller: C, path: String, body: AnyBody, stream: @escaping Stream<State>) where C.State == State {
    streams[id] = Task {
      do {
        let bodyParam = AnonymousBody(body: body, sender: controller.sender, state: controller.state)
        let values = stream(bodyParam, path)
        for try await value in values {
          controller.respond(Response(id: id, body: value))
        }
        controller.respond(Response(id: id, done: true))
      } catch {
        controller.respond(Response(id: id, error: ChannelError(error: error)))
      }
      streams[id] = nil
    }
  }
  
  public func events(_ events: Any, prefix: String = "") -> Self {
    if self.eventsApi == nil {
      self.eventsApi = [String: SubscriptionProtocol]()
    }
    let p = prefix.count > 0 ? "\(prefix)/" : ""
    if var e = self.eventsApi {
      if let eventsMap = events as? [String: SubscriptionProtocol] {
        for (key, value) in eventsMap {
          e[p + key] = value
        }
        self.eventsApi = e
      } else {
        parseSubscription(events, prefix, &self.eventsApi!)
      }
    }
    return self
  }
}

// MARK: - Sender
public protocol Sender: Sendable {
  associatedtype State: Sendable
  @MainActor
  func send<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) async throws -> Output
  @MainActor
  func values<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) -> Values<State, Body, Output>
  @MainActor
  func subscribe<Body: Encodable & Sendable>(_ path: String, _ body: Body?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable
  @MainActor
  func stop()
}
public protocol ProxySender: Sender where ParentSender.State == State {
  associatedtype ParentSender: Sender
  var sender: ParentSender { get }
}

@MainActor
public extension ProxySender {
  func send<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) async throws -> Output {
    try await sender.send(path, body)
  }
  func values<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) -> Values<State, Body, Output> {
    sender.values(path, body)
  }
  func subscribe<Body: Encodable & Sendable>(_ path: String, _ body: Body?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    try await sender.subscribe(path, body, event: event)
  }
  func stop() {
    sender.stop()
  }
}
@MainActor
public extension Sender {
  func send<Output: Decodable>(_ path: String) async throws -> Output {
    try await send(path, Optional<EmptyCodable>.none)
  }
  func send<Body: Encodable>(_ path: String, _ body: Body?) async throws {
    _ = try await send(path, body) as EmptyCodable?
  }
  func send(_ path: String) async throws {
    _ = try await send(path, Optional<EmptyCodable>.none) as EmptyCodable?
  }
  func values<Output: Decodable>(_ path: String, as: Output.Type = Output.self) -> Values<State, EmptyCodable, Output> {
    values(path, Optional<EmptyCodable>.none)
  }
  func subscribe(_ path: String, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    try await subscribe(path, Optional<EmptyCodable>.none, event: event)
  }
}
@MainActor
public struct ChannelSender<State: Sendable>: Sender, @unchecked Sendable {
  let ch: Channel<State>
  let connection: ConnectionInterface
  
  public init(ch: Channel<State>, connection: ConnectionInterface) {
    self.ch = ch
    self.connection = connection
  }
  
  public func send<Body: Encodable & Sendable, Output: Decodable>(_ path: String, _ body: Body?) async throws -> Output {
    return try await withCheckedThrowingContinuation { continuation in
      let id = UnsafeMutable<Int?>(nil)
      let request = self.ch.makeRequest(path, body) { response in
        if let error = response.error {
          continuation.resume(throwing: ChannelError(text: error))
        } else {
          do {
            try continuation.resume(returning: response.anyBody.body())
          } catch {
            continuation.resume(throwing: error)
          }
        }
        if let id = id.value {
          self.connection.sent(id)
        }
      }
      id.value = self.connection.send(request)
    }
  }
  
  public func values<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) -> Values<State, Body, Output> {
    Values(ch: ch, path: path, body: body, connection: connection)
  }
  
  public func subscribe<Body: Encodable & Sendable>(_ path: String, _ body: Body?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    return try await withCheckedThrowingContinuation { continuation in
      let request = self.ch.makeSubscription(path, body) { response in
        if let error = response.error {
          continuation.resume(throwing: ChannelError(text: error))
        } else {
          let topic = response.topic ?? ""
          let cancelClosure = self.connection.addTopic(topic: topic, event: event)
          let cancellable = _AnyCancellable {
            Task { @MainActor in
              let cancelled = cancelClosure()
              if cancelled {
                self.connection.notify(["unsub": topic])
              }
            }
          }
          continuation.resume(returning: cancellable)
        }
      }
      _ = self.connection.send(request)
    }
  }
  
  public func stop() {
    self.connection.stop()
  }
}

// MARK: - Stream
@MainActor
public class Values<State: Sendable, Body: Encodable & Sendable, Output: Decodable & Sendable>: AsyncSequence, AsyncIteratorProtocol, @unchecked Sendable {
  public typealias Element = Output
  
  private let ch: Channel<State>
  private let path: String
  private let body: Body?
  private let connection: ConnectionInterface
  private var isRunning = false
  private var pending: [((Result<Element?, Error>) -> Void)] = []
  private var queued: [Result<Element?, Error>] = []
  private var rid: Int?
  private var isCompleted: Bool = false
  private var connectionRequestId: Int?
  
  init(ch: Channel<State>, path: String, body: Body?, connection: ConnectionInterface) {
    self.ch = ch
    self.path = path
    self.body = body
    self.connection = connection
  }
  
  private func onCancel(id: Int) {
    if let connectionRequestId, !self.connection.cancel(connectionRequestId) {
      _ = self.connection.notify(["cancel": id])
    }
  }
  
  private func onComplete() {
    if let connectionRequestId {
      _ = self.connection.cancel(connectionRequestId)
    }
  }
  
  private func start() {
    if self.isRunning { return }
    self.isRunning = true
    let request = self.ch.makeStream(self.path, self.body) { response in
      let result = Result<Element?, Error> { try response.parseStream() }
      if !self.pending.isEmpty {
        let pendingClosure = self.pending.removeFirst()
        pendingClosure(result)
      } else {
        self.queued.append(result)
      }
    }
    self.rid = request.id
    connectionRequestId = self.connection.send(body)
  }
  
  public func next() async throws -> Element? {
    do {
      let value = try await _next()
      if value == nil {
        isCompleted = true
        onComplete()
      }
      return value
    } catch {
      onComplete()
      throw error
    }
  }
  private func _next() async throws -> Element? {
    if !queued.isEmpty {
      return try queued.removeFirst().get()
    } else {
      var cancel: (@Sendable () -> ())?
      var isCancelled = false
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element?, Error>) in
          cancel = { continuation.resume(throwing: CancellationError()) }
          DispatchQueue.main.async {
            if self.queued.count > 0 {
              continuation.resume(with: self.queued.removeFirst())
            } else {
              self.pending.append { response in
                guard !isCancelled else { return }
                continuation.resume(with: response)
              }
              self.start()
            }
          }
        }
      } onCancel: {
        Task { @MainActor in
          if let rid {
            isCancelled = true
            onCancel(id: rid)
            cancel?()
          }
        }
      }
    }
  }
  nonisolated public func makeAsyncIterator() -> Values {
    return self
  }
}
private extension ReceivedResponse {
  func parseStream<T: Decodable>() throws -> T? {
    if done == true {
      return try? anyBody.body()
    } else if let error {
      throw ChannelError(text: error)
    } else {
      return try anyBody.body()
    }
  }
}

final class UnsafeMutable<Value: Sendable>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) {
    self.value = value
  }
}

public protocol _Cancellable {
  func cancel()
}
private class _AnyCancellable: _Cancellable {
  private let canceller: @Sendable () -> Void
  init(canceller: @Sendable @escaping () -> Void) {
    self.canceller = canceller
  }
  func cancel() {
    self.canceller()
  }
  deinit { canceller() }
}

// MARK: - Events
func parseSubscription(_ object: Any, _ prefix: String, _ map: inout [String: SubscriptionProtocol]) {
  guard let dict = object as? [String: Any] else { return }
  for (key, value) in dict {
    if let subscription = value as? SubscriptionProtocol {
      subscription.prefix = prefix.count > 0 ? "\(prefix)/\(key)" : key
      map[prefix + key] = subscription
      continue
    } else if let value = value as? [String: Any] {
      parseSubscription(value, "\(prefix)\(key)/", &map)
    }
  }
}
public protocol EventPublisher {
  func publish(_ event: SubscriptionEvent)
}

public struct SubscriptionEvent {
  public var topic: String
  public var body: Encodable
}
public protocol SubscriptionProtocol: AnyObject {
  var prefix: String { get set }
  var publishers: [EventPublisher] { get set }
  func getTopic(request: AnyBody) throws -> String
  func getBody(request: AnyBody) throws -> (Encodable & Sendable)?
}
public class Subscription<Input: Decodable, Output: Encodable & Sendable>: SubscriptionProtocol {
  public var publishers: [EventPublisher] = []
  public var prefix: String = ""
  private let _topic: (Input) -> String
  private let _body: (Input) -> Output?
  
  public init(topic: @escaping (Input) -> String, body: @escaping (Input) -> Output?) {
    self._topic = topic
    self._body = body
  }
  
  public func send(_ request: Input, body: Output?) {
    let topic = self._topic(request)
    let output: Output? = body ?? self._body(request)
    publish(topic, body: output)
  }
  
  public func publish(_ topic: String, body: Output? = nil) {
    guard let body else { return }
    let fullTopic = self.prefix.count > 0 ? "\(self.prefix)/\(topic)" : topic
    let event = SubscriptionEvent(topic: fullTopic, body: body)
    for pub in self.publishers {
      pub.publish(event)
    }
  }
  public func getTopic(request: AnyBody) throws -> String {
    try self._topic(request.body())
  }
  public func getBody(request: AnyBody) throws -> (Encodable & Sendable)? {
    try self._body(request.body())
  }
}


// MARK: - Codable
public struct AnyBody: @unchecked Sendable {
  private let container: KeyedDecodingContainer<ReceivedResponse.CodingKeys>
  init(container: KeyedDecodingContainer<ReceivedResponse.CodingKeys>) {
    self.container = container
  }
  func body<Body: Decodable>() throws -> Body {
    if let optional = Body.self as? any OptionalDecodable.Type {
      try optional.decode(container, key: .body) as! Body
    } else {
      try container.decode(Body.self, forKey: .body)
    }
  }
}

protocol OptionalDecodable {
  static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, key: K) throws -> Any?
}
extension Optional: OptionalDecodable where Wrapped: Decodable {
  static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, key: K) throws -> Any? {
    guard container.contains(key) else { return nil }
    return try container.decode(Optional<Wrapped>.self, forKey: key) as Self
  }
}

public enum DecodableArray<Element: Decodable>: Decodable {
  case one(Element)
  case many([Element])
  var array: [Element] {
    switch self {
    case .one(let e): return [e]
    case .many(let a): return a
    }
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    do {
      self = try .many(container.decode([Element].self))
    } catch {
      self = try .one(container.decode(Element.self))
    }
  }
}

public struct EmptyCodable: Codable, Sendable { }
