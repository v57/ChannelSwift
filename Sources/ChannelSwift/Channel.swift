//
//  File.swift
//  ChannelSwift
//
//  Created by Dmitry Kozlov on 22/4/25.
//

import Foundation

// MARK: - Protocols

public protocol Controller {
  associatedtype State
  func respond(_ response: Encodable)
  func subscribe(_ topic: String)
  func unsubscribe(_ topic: String)
  func event(_ topic: String, _ event: AnyBody)
  var sender: any Sender { get }
  var state: State { get }
}
protocol StreamRequestProtocol { }

public protocol ConnectionInterface {
  @discardableResult
  func send<Body: Encodable>(_ body: Body) -> Int
  func sent(_ id: Int)
  func cancel(_ id: Int) -> Bool
  func notify<Body: Encodable>(_ body: Body)
  func addTopic(topic: String, event: @escaping (AnyBody) -> Void) -> () -> Bool
  func stop()
}

// MARK: - Types
public typealias Function<State> = (Body<State>, String) async throws -> Encodable
public typealias Stream<State> = (Body<State>, String) -> AsyncThrowingStream<Encodable, Error>
public struct Request<Body: Encodable>: Encodable {
  public var id: Int
  public var path: String
  public var body: Body?
  public init(id: Int, path: String, body: Body? = nil) {
    self.id = id
    self.path = path
    self.body = body
  }
}
public struct Body<State> {
  public var body: Any
  public var sender: any Sender
  public var state: State
  public init(body: Any, sender: any Sender, state: State) {
    self.body = body
    self.sender = sender
    self.state = state
  }
}

public struct SubscriptionRequest<Body: Encodable>: Encodable {
  public var id: Int
  public var sub: String
  public var body: Body?
  
  public init(id: Int, sub: String, body: Body? = nil) {
    self.id = id
    self.sub = sub
    self.body = body
  }
}

public struct StreamRequest<Body: Encodable>: Encodable, StreamRequestProtocol {
  public var id: Int
  public var stream: String
  public var body: Body?
  
  public init(id: Int, stream: String, body: Body? = nil) {
    self.id = id
    self.stream = stream
    self.body = body
  }
}

public struct Response: Encodable {
  public var id: Int
  public var topic: String?
  public var body: Encodable?
  public var error: ChannelError?
  public var done: Bool?
  
  public init(id: Int, topic: String? = nil, body: Encodable? = nil, error: ChannelError? = nil, done: Bool? = nil) {
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
public struct ReceivedResponse: Decodable {
  var id: Int?
  var path: String?
  var stream: String?
  var cancel: Int?
  var sub: String?
  var unsub: String?
  var topic: String?
  var done: Bool?
  var error: String?
  var container: KeyedDecodingContainer<CodingKeys>
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
public struct ChannelError: Error, Codable {
  public let text: String
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

public struct PendingRequest {
  public var request: Encodable
  public var onResponse: (ReceivedResponse) -> Void
  public init(request: Encodable, response: @escaping (ReceivedResponse) -> Void) {
    self.request = request
    self.onResponse = response
  }
}

// MARK: - Channel
public class Channel<State> {
  private var id = 0
  public var publish: (_ topic: String, _ body: Any) -> Void = { _, _ in }
  public var requests: [Int: PendingRequest] = [:]
  public var postApi: [String: Function<State>] = [:]
  public var otherPostApi: [(path: (String) -> Bool, request: Function<State>)] = []
  public var streamApi: [String: Stream<State>] = [:]
  public var otherStreamApi: [(path: (String) -> Bool, request: Stream<State>)] = []
  public var _onDisconnect: ((State, any Sender) -> Void)?
  public var eventsApi: [String: SubscriptionProtocol]?
  private var streams: [Int: Task<Void, Error>] = [:]
  
  public init() { }
  
  public func post(_ path: String, request: @escaping Function<State>) -> Self {
    self.postApi[path] = request
    return self
  }
  
  public func postOther(_ path: @escaping (String) -> Bool, request: @escaping Function<State>) -> Self {
    self.otherPostApi.append((path: path, request: request))
    return self
  }
  public func stream(_ path: String, request: @escaping Stream<State>) -> Self {
    self.streamApi[path] = request
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
  
  public func makeRequest<Body: Encodable>(_ path: String, _ body: Body?, response: @escaping (ReceivedResponse) -> Void) -> Request<Body> {
    let id = self.id
    self.id += 1
    let pending = PendingRequest(request: Request(id: id, path: path, body: body), response: response)
    self.requests[id] = pending
    return Request(id: id, path: path, body: body)
  }
  
  public func makeStream<Body: Encodable>(_ stream: String, _ body: Body?, response: @escaping (ReceivedResponse) -> Void) -> StreamRequest<Body> {
    let id = self.id
    self.id += 1
    let pending = PendingRequest(request: StreamRequest(id: id, stream: stream, body: body), response: response)
    self.requests[id] = pending
    return StreamRequest(id: id, stream: stream, body: body)
  }
  
  public func makeSubscription<Body: Encodable>(_ sub: String, _ body: Body?, response: @escaping (ReceivedResponse) -> Void) -> SubscriptionRequest<Body> {
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
        let bodyParam = Body(body: AnyBody(container: some.container), sender: controller.sender, state: controller.state)
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
        self.requests.removeValue(forKey: id)
      }
      request.onResponse(some)
    }
  }
  
  private func streamRequest<C: Controller>(_ id: Int, controller: C, path: String, body: AnyBody, stream: @escaping Stream<State>) where C.State == State {
    self.streams[id] = Task {
      do {
        let bodyParam = Body(body: body as Any, sender: controller.sender, state: controller.state)
        let values = stream(bodyParam, path)
        for try await value in values {
          controller.respond(Response(id: id, body: value))
        }
        controller.respond(Response(id: id, done: true))
      } catch {
        controller.respond(Response(id: id, error: ChannelError(error: error)))
      }
      self.streams[id] = nil
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
public protocol Sender {
  associatedtype State
  func send<Body: Encodable, Output: Decodable>(_ path: String, body: Body?) async throws -> Output
  func values<Body: Encodable, Output: Decodable>(_ path: String, body: Body?) -> Values<State, Body, Output>
  func subscribe<Body: Encodable>(_ path: String, body: Body?, event: @escaping (Any) -> Void) async throws -> _Cancellable
  func stop()
}
public protocol ProxySender: Sender where ParentSender.State == State {
  associatedtype ParentSender: Sender
  var sender: ParentSender { get }
}
public extension ProxySender {
  func send<Body: Encodable, Output: Decodable>(_ path: String, body: Body?) async throws -> Output {
    try await sender.send(path, body: body)
  }
  func values<Body: Encodable, Output: Decodable>(_ path: String, body: Body?) -> Values<State, Body, Output> {
    sender.values(path, body: body)
  }
  func subscribe<Body: Encodable>(_ path: String, body: Body?, event: @escaping (Any) -> Void) async throws -> _Cancellable {
    try await sender.subscribe(path, body: body, event: event)
  }
  func stop() {
    sender.stop()
  }
}
public extension Sender {
  func send<Output: Decodable>(_ path: String) async throws -> Output {
    try await send(path, body: Optional<EmptyCodable>.none)
  }
  func send<Body: Encodable>(_ path: String, body: Body?) async throws {
    _ = try await send(path, body: body) as EmptyCodable?
  }
  func send(_ path: String) async throws {
    _ = try await send(path, body: Optional<EmptyCodable>.none) as EmptyCodable?
  }
  func values<Output: Decodable>(_ path: String, as: Output.Type = Output.self) -> Values<State, EmptyCodable, Output> {
    values(path, body: Optional<EmptyCodable>.none)
  }
  func subscribe(_ path: String, event: @escaping (Any) -> Void) async throws -> _Cancellable {
    try await subscribe(path, body: Optional<EmptyCodable>.none, event: event)
  }
}

public struct ChannelSender<State>: Sender {
  let ch: Channel<State>
  let connection: ConnectionInterface
  
  public init(ch: Channel<State>, connection: ConnectionInterface) {
    self.ch = ch
    self.connection = connection
  }
  
  public func send<Body: Encodable, Output: Decodable>(_ path: String, body: Body?) async throws -> Output {
    return try await withCheckedThrowingContinuation { continuation in
      var id: Int?
      let request = self.ch.makeRequest(path, body) { response in
        if let error = response.error {
          continuation.resume(throwing: NSError(domain: "SenderError", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
        } else {
          do {
            try continuation.resume(returning: response.anyBody.body())
          } catch {
            continuation.resume(throwing: error)
          }
        }
        if let id {
          self.connection.sent(id)
        }
      }
      id = self.connection.send(request)
    }
  }
  
  public func values<Body: Encodable, Output: Decodable>(_ path: String, body: Body?) -> Values<State, Body, Output> {
    var rid: Int?
    return Values(ch: ch, path: path, body: body, onSend: { req in
      rid = self.connection.send(req)
    }, onCancel: { id in
      if let existing = rid, !self.connection.cancel(existing) {
        _ = self.connection.send(["cancel": id])
      }
    })
  }
  
  public func subscribe<Body: Encodable>(_ path: String, body: Body?, event: @escaping (Any) -> Void) async throws -> _Cancellable {
    return try await withCheckedThrowingContinuation { continuation in
      let request = self.ch.makeSubscription(path, body) { response in
        if let error = response.error {
          continuation.resume(throwing: NSError(domain: "SenderError", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
        } else {
          let topic = response.topic ?? ""
          let cancelClosure = self.connection.addTopic(topic: topic, event: event)
          let cancellable = _AnyCancellable {
            let cancelled = cancelClosure()
            if cancelled {
              self.connection.notify(["unsub": topic])
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
public class Values<State, Body: Encodable, Output: Decodable>: AsyncSequence, AsyncIteratorProtocol {
  public typealias Element = Output
  
  private var ch: Channel<State>
  private var path: String
  private var body: Body?
  private var isRunning = false
  private var pending: [((ReceivedResponse) -> Void)] = []
  private var queued: [ReceivedResponse] = []
  private var rid: Int?
  private var onSend: (StreamRequest<Body>) -> Void
  private var onCancel: (Int) -> Void
  
  init(ch: Channel<State>, path: String, body: Body?, onSend: @escaping (StreamRequest<Body>) -> Void, onCancel: @escaping (Int) -> Void) {
    self.ch = ch
    self.path = path
    self.body = body
    self.onSend = onSend
    self.onCancel = onCancel
  }
  
  private func start() {
    if self.isRunning { return }
    self.isRunning = true
    let request = self.ch.makeStream(self.path, self.body) { response in
      if !self.pending.isEmpty {
        let pendingClosure = self.pending.removeFirst()
        pendingClosure(response)
      } else {
        self.queued.append(response)
      }
    }
    self.rid = request.id
    self.onSend(request)
  }
  
  public func next() async throws -> Element? {
    try await withCheckedThrowingContinuation { continuation in
      self.pending.append { response in
        do {
          if response.done == true {
            continuation.resume(returning: try? response.anyBody.body())
          } else {
            try continuation.resume(returning: response.anyBody.body())
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
      self.start()
    }
  }
  public func makeAsyncIterator() -> Values {
    return self
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
  func getTopic(request: AnyBody) throws -> String
  func getBody(request: AnyBody) throws -> Encodable?
}
public class Subscription<Input: Decodable, Output: Encodable>: SubscriptionProtocol {
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
  public func getBody(request: AnyBody) throws -> Encodable? {
    try self._body(request.body())
  }
}


// MARK: - Codable
public struct AnyBody {
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

public struct EmptyCodable: Codable { }
