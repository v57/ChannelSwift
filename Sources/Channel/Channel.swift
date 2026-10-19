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
protocol SubscriptionRequestProtocol: Sendable { }

@MainActor
public protocol ConnectionInterface: Sendable {
  @discardableResult
  func send<Body: Encodable>(_ body: Body) -> Int
  func sent(_ id: Int)
  func cancel(_ id: Int) -> Bool
  func notify<Body: Encodable>(_ body: Body)
  func addTopic(topic: String, event: @escaping @MainActor (AnyBody) -> Void) -> @Sendable @MainActor () -> Bool
  func stop()
  /// Sends a request that waits for a response. `options.fail` is called when the connection gives up on it.
  @discardableResult
  func send<Body: Encodable>(_ body: Body, options: RequestOptions) -> Int
  /// Default timeout in seconds for posts and subscription responses
  var requestTimeout: TimeInterval? { get }
}
public extension ConnectionInterface {
  @discardableResult
  func send<Body: Encodable>(_ body: Body, options: RequestOptions) -> Int {
    send(body)
  }
  var requestTimeout: TimeInterval? { nil }
}

/// How a connection treats a pending request
public struct RequestOptions: Sendable {
  /// Send the request again after a reconnect when it was written to the socket and got no response
  public var replay: Bool
  /// Called when the request fails without a response: `disconnected` after a drop with `replay: false`, or on `stop()`
  public var fail: (@Sendable @MainActor (ChannelError) -> Void)?
  public init(replay: Bool = true, fail: (@Sendable @MainActor (ChannelError) -> Void)? = nil) {
    self.replay = replay
    self.fail = fail
  }
}

public struct SendOptions<Context: Encodable & Sendable>: Sendable {
  public var context: Context?
  /// Seconds to wait for the response (posts and subscription responses, not stream values). Fails with code `timeout`.
  public var timeout: TimeInterval?
  /// Send the request again after a reconnect. With `false`, a request already written fails with `disconnected`.
  public var replay: Bool
  public init(context: Context? = nil, timeout: TimeInterval? = nil, replay: Bool = true) {
    self.context = context
    self.timeout = timeout
    self.replay = replay
  }
}
public extension SendOptions where Context == EmptyCodable {
  init(timeout: TimeInterval? = nil, replay: Bool = true) {
    self.init(context: nil, timeout: timeout, replay: replay)
  }
}

// MARK: - Types
public typealias Function<State> = @Sendable (AnonymousBody<State>, String) async throws -> Encodable & Sendable
public typealias Stream<State> = @Sendable (AnonymousBody<State>, String) -> AsyncThrowingStream<Encodable & Sendable, Error>
public struct Request<Body: Encodable & Sendable, Context: Encodable & Sendable>: Encodable, Sendable {
  public var id: Int
  public var path: String
  public var body: Body?
  public var context: Context?
  public init(id: Int, path: String, body: Body?, context: Context?) {
    self.id = id
    self.path = path
    self.body = body
    self.context = context
  }
}
public struct AnonymousBody<State: Sendable>: Sendable {
  public var body: AnyBody
  public var sender: any Sender
  public var state: State
}
public struct Body<Body: Decodable & Sendable, Context: Decodable & Sendable, State: Sendable>: Sendable {
  public var body: Body
  public var context: Context
  public var sender: any Sender
  public var state: State
}

public struct SubscriptionRequest<Body: Encodable & Sendable, Context: Encodable & Sendable>: Encodable, SubscriptionRequestProtocol {
  public var id: Int
  public var sub: String
  public var body: Body?
  public var context: Context?
  
  public init(id: Int, sub: String, body: Body?, context: Context?) {
    self.id = id
    self.sub = sub
    self.body = body
    self.context = context
  }
}

public struct StreamRequest<Body: Encodable & Sendable, Context: Encodable & Sendable>: Encodable, StreamRequestProtocol {
  public var id: Int
  public var stream: String
  public var body: Body?
  public var context: Context?
  
  public init(id: Int, stream: String, body: Body?, context: Context?) {
    self.id = id
    self.stream = stream
    self.body = body
    self.context = context
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
    case id, topic, body, error, code, done
  }
  public func encode(to encoder: any Encoder) throws {
    var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.id, forKey: CodingKeys.id)
    try container.encodeIfPresent(self.topic, forKey: CodingKeys.topic)
    if let body {
      try container.encode(body, forKey: CodingKeys.body)
    }
    try container.encodeIfPresent(self.error, forKey: CodingKeys.error)
    try container.encodeIfPresent(self.error?.code, forKey: CodingKeys.code)
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
  /// The message has a `body` key, `null` included
  var hasBody: Bool { container.contains(.body) }
  var channelError: ChannelError? {
    guard let error else { return nil }
    let code = try? container.decodeIfPresent(ChannelError.Code.self, forKey: .code)
    let info = container.contains(.info) ? AnyBody(container: container, key: .info) : nil
    return ChannelError(text: error, code: code, info: info)
  }
  
  enum CodingKeys: CodingKey {
    case id, path, body, context, stream, cancel, sub, unsub, topic, done, error, code, info, message
  }
  
  // A field with an unexpected type reads as missing, so one odd field doesn't drop the whole frame
  public init(from decoder: any Decoder) throws {
    container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try? container.decodeIfPresent(Int.self, forKey: .id)
    self.path = try? container.decodeIfPresent(String.self, forKey: .path)
    self.stream = try? container.decodeIfPresent(String.self, forKey: .stream)
    self.cancel = try? container.decodeIfPresent(Int.self, forKey: .cancel)
    self.sub = try? container.decodeIfPresent(String.self, forKey: .sub)
    self.unsub = try? container.decodeIfPresent(String.self, forKey: .unsub)
    self.topic = try? container.decodeIfPresent(String.self, forKey: .topic)
    self.done = try? container.decodeIfPresent(Bool.self, forKey: .done)
    if container.contains(.error), (try? container.decodeNil(forKey: .error)) == false {
      if let text = try? container.decode(String.self, forKey: .error) {
        self.error = text.isEmpty ? "error" : text
      } else if let text = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .error).decode(String.self, forKey: .message) {
        self.error = text
      } else {
        self.error = "error"
      }
    }
  }
}
public struct ChannelError: Error, CustomStringConvertible, Codable, Sendable {
  /// Error code: an application code (often HTTP-like numbers) or a library code like `timeout`
  public enum Code: Codable, Hashable, Sendable, CustomStringConvertible, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case int(Int), string(String)
    /// No handler for the path or subscription
    public static let notFound: Code = "not_found"
    /// The server-side task was cancelled
    public static let cancelled: Code = "cancelled"
    /// Refused by a rate limiter, `info: { retryAfter: seconds }`
    public static let rateLimited: Code = "rate_limited"
    /// Client only: no response in time
    public static let timeout: Code = "timeout"
    /// Client only: the connection dropped and the request can't be replayed, or `stop()` was called
    public static let disconnected: Code = "disconnected"
    /// Client only: the response didn't decode into the expected type
    public static let decoding: Code = "decoding"
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(Int.self) {
        self = .int(value)
      } else {
        self = try .string(container.decode(String.self))
      }
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .int(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      }
    }
    public var description: String {
      switch self {
      case .int(let value): "\(value)"
      case .string(let value): value
      }
    }
  }
  public let text: String
  public var code: Code?
  /// Any JSON the server attached to the error. Decode it with `info?.decode(T.self)`.
  public var info: AnyBody?
  public var localizedDescription: String { text }
  public var description: String { text }
  public init(text: String) {
    self.text = text
  }
  public init(text: String, code: Code?, info: AnyBody? = nil) {
    self.text = text
    self.code = code
    self.info = info
  }
  public init?(optional: String?) {
    guard let optional else { return nil }
    self.text = optional
  }
  public init(error: Error) {
    if let error = error as? ChannelError {
      self = error
    } else {
      text = "internal error"
    }
  }
  static var timeout: ChannelError { ChannelError(text: "timeout", code: .timeout) }
  static var disconnected: ChannelError { ChannelError(text: "disconnected", code: .disconnected) }
  static func decoding(_ error: Error) -> ChannelError {
    if let error = error as? ChannelError { return error }
    return ChannelError(text: "decoding: \(error)", code: .decoding)
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
  private var tasks: [Int: Task<Void, Never>] = [:]
  
  public init() { }
  
  public func post<Input: Decodable, Context: Decodable, Output: Encodable & Sendable>(_ path: String, request: @escaping ( @Sendable (Body<Input, Context, State>) async throws -> Output)) -> Self {
    postApi[path] = { body, _ in
      try await request(Body(body: body.body.body(), context: body.body.context(), sender: body.sender, state: body.state))
    }
    return self
  }
  public func post<Input: Decodable & Sendable, Output: Encodable & Sendable>(_ path: String, request: @escaping @Sendable (Input) async throws -> Output) -> Self {
    postApi[path] = { body, _ in
      try await request(body.body.body())
    }
    return self
  }
  public func post<Input: Decodable & Sendable>(_ path: String, request: @escaping (@Sendable (Input) async throws -> Void)) -> Self {
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
  public func stream<Input: Decodable & Sendable, Context: Decodable & Sendable>(_ path: String, request: @escaping @Sendable (Body<Input, Context, State>, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    streamApi[path] = { body, _ in
      AsyncThrowingStream { continuation in
        Task {
          do {
            try await request(Body(body: body.body.body(), context: body.body.context(), sender: body.sender, state: body.state), continuation)
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
    stream(path) { (body: Body<Input, EmptyCodable, State>, continuation) in
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
  
  public func makeRequest<Body: Encodable, Context: Encodable>(_ path: String, _ body: Body?, _ options: SendOptions<Context>?, response: @escaping @Sendable @MainActor (ReceivedResponse) -> Void) -> Request<Body, Context> {
    let id = self.id
    self.id += 1
    let request = Request(id: id, path: path, body: body, context: options?.context)
    let pending = PendingRequest(request: request, response: response)
    self.requests[id] = pending
    return request
  }
  
  public func makeStream<Body: Encodable, Context: Encodable>(_ stream: String, _ body: Body?, _ options: SendOptions<Context>?, response: @escaping @Sendable @MainActor (ReceivedResponse) -> Void) -> StreamRequest<Body, Context> {
    let id = self.id
    self.id += 1
    let request = StreamRequest(id: id, stream: stream, body: body, context: options?.context)
    let pending = PendingRequest(request: request, response: response)
    self.requests[id] = pending
    return request
  }
  
  public func makeSubscription<Body: Encodable, Context: Encodable>(_ sub: String, _ body: Body?, _ options: SendOptions<Context>?, response: @escaping @Sendable @MainActor (ReceivedResponse) -> Void) -> SubscriptionRequest<Body, Context> {
    let id = self.id
    self.id += 1
    let request = SubscriptionRequest(id: id, sub: sub, body: body, context: options?.context)
    let pending = PendingRequest(request: request, response: response)
    self.requests[id] = pending
    return request
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
        guard let api else { throw ChannelError(text: "api not found", code: .notFound) }
        let body = AnonymousBody(body: AnyBody(container: some.container), sender: controller.sender, state: controller.state)
        let task = Task {
          do {
            let result = try await api(body, path)
            if let id {
              controller.respond(Response(id: id, body: result))
            }
          } catch is CancellationError { } catch {
            if let id {
              controller.respond(Response(id: id, error: ChannelError(error: error)))
            }
          }
          if let id {
            tasks[id] = nil
          }
        }
        if let id {
          tasks[id] = task
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
        // Checking id first works around a Swift 6.4 optimizer crash (CopyPropagation) in Release builds.
        guard let id else { throw ChannelError(text: "stream requires id") }
        guard let api else { throw ChannelError(text: "api not found", code: .notFound) }
        self.streamRequest(id, controller: controller, path: path, body: some.anyBody, stream: api)
      } catch {
        if let id {
          controller.respond(Response(id: id, error: ChannelError(error: error)))
        }
      }
    } else if let id = some.cancel {
      if let task = tasks[id] {
        task.cancel()
        tasks[id] = nil
      }
    } else if let sub = some.sub {
      let id = some.id
      guard let subscription = self.eventsApi?[sub] else {
        if let id {
          controller.respond(Response(id: id, error: ChannelError(text: "subscription not found", code: .notFound)))
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
    } else if let id = some.id {
      guard let request = self.requests[id] else { return }
      // Subscriptions stay while active, so a resubscribe after a reconnect finds its handler
      if !(request.request is SubscriptionRequestProtocol) && !((request.request is StreamRequestProtocol) && (some.done != true) && some.error == nil) {
        self.requests[id] = nil
      }
      request.onResponse(some)
    } else if let topic = some.topic {
      // Only a missing body means no event: 0, false, "" and null are delivered
      guard some.hasBody else { return }
      controller.event(topic, some.anyBody)
    }
  }
  
  private func streamRequest<C: Controller>(_ id: Int, controller: C, path: String, body: AnyBody, stream: @escaping Stream<State>) where C.State == State {
    tasks[id] = Task {
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
      tasks[id] = nil
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
  func send<Body: Encodable, Context: Encodable, Output: Decodable>(_ path: String, _ body: Body?, options: SendOptions<Context>?) async throws -> Output
  @MainActor
  func values<Body: Encodable, Context: Encodable, Output: Decodable>(_ path: String, _ body: Body?, options: SendOptions<Context>?) -> Values<State, Body, Context, Output>
  @MainActor
  func subscribe<Body: Encodable & Sendable, Context: Encodable & Sendable>(_ path: String, _ body: Body?, options: SendOptions<Context>?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable
  @MainActor
  func stop()
}
public protocol ProxySender: Sender where ParentSender.State == State {
  associatedtype ParentSender: Sender
  var sender: ParentSender { get }
}

@MainActor
public extension ProxySender {
  func send<Body: Encodable, Context: Encodable, Output: Decodable>(_ path: String, _ body: Body?, options: SendOptions<Context>?) async throws -> Output {
    try await sender.send(path, body, options: options)
  }
  func values<Body: Encodable, Context: Encodable, Output: Decodable>(_ path: String, _ body: Body?, options: SendOptions<Context>?) -> Values<State, Body, Context, Output> {
    sender.values(path, body, options: options)
  }
  func subscribe<Body: Encodable & Sendable, Context: Encodable & Sendable>(_ path: String, _ body: Body?, options: SendOptions<Context>?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    try await sender.subscribe(path, body, options: options, event: event)
  }
  func stop() {
    sender.stop()
  }
}
@MainActor
public extension Sender {
  func send<Output: Decodable>(_ path: String) async throws -> Output {
    try await send(path, Optional<EmptyCodable>.none, options: Optional<SendOptions<EmptyCodable>>.none)
  }
  func send<Body: Encodable>(_ path: String, _ body: Body?) async throws {
    _ = try await send(path, body, options: Optional<SendOptions<EmptyCodable>>.none) as EmptyCodable?
  }
  func send(_ path: String) async throws {
    _ = try await send(path, Optional<EmptyCodable>.none, options: Optional<SendOptions<EmptyCodable>>.none) as EmptyCodable?
  }
  func send<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) async throws -> Output {
    try await send(path, body, options: Optional<SendOptions<EmptyCodable>>.none)
  }
  func send<Output: Decodable, Context: Encodable>(_ path: String, options: SendOptions<Context>?) async throws -> Output {
    try await send(path, Optional<EmptyCodable>.none, options: options)
  }
  func send<Body: Encodable, Context: Encodable>(_ path: String, _ body: Body?, options: SendOptions<Context>?) async throws {
    _ = try await send(path, body, options: options) as EmptyCodable?
  }
  func send<Context: Encodable>(_ path: String, options: SendOptions<Context>?) async throws {
    _ = try await send(path, Optional<EmptyCodable>.none, options: options) as EmptyCodable?
  }
  func values<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) -> Values<State, Body, EmptyCodable, Output> {
    values(path, body, options: Optional<SendOptions<EmptyCodable>>.none)
  }
  func values<Output: Decodable>(_ path: String, as: Output.Type = Output.self) -> Values<State, EmptyCodable, EmptyCodable, Output> {
    values(path, Optional<EmptyCodable>.none, options: Optional<SendOptions<EmptyCodable>>.none)
  }
  func values<Context: Encodable, Output: Decodable>(_ path: String, options: SendOptions<Context>?) -> Values<State, EmptyCodable, Context, Output> {
    values(path, Optional<EmptyCodable>.none, options: options)
  }
  func values<Output: Decodable, Context: Encodable>(_ path: String, _ options: SendOptions<Context>?, as: Output.Type = Output.self) -> Values<State, EmptyCodable, Context, Output> {
    values(path, Optional<EmptyCodable>.none, options: options)
  }
  func subscribe<Context: Encodable & Sendable>(_ path: String, options: SendOptions<Context>?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    try await subscribe(path, Optional<EmptyCodable>.none, options: options, event: event)
  }
  func subscribe<Body: Encodable & Sendable>(_ path: String, _ body: Body?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    try await subscribe(path, body, options: Optional<SendOptions<EmptyCodable>>.none, event: event)
  }
  func subscribe(_ path: String, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    try await subscribe(path, Optional<EmptyCodable>.none, options: Optional<SendOptions<EmptyCodable>>.none, event: event)
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
  
  public func send<Body: Encodable & Sendable, Context: Encodable & Sendable, Output: Decodable>(_ path: String, _ body: Body?, options: SendOptions<Context>?) async throws -> Output {
    let ch = self.ch
    let connection = self.connection
    return try await withCheckedThrowingContinuation { continuation in
      let call = PendingCall()
      let request = ch.makeRequest(path, body, options) { response in
        call.finish(connection)
        if let error = response.channelError {
          continuation.resume(throwing: error)
        } else {
          do {
            try continuation.resume(returning: response.anyBody.body())
          } catch {
            continuation.resume(throwing: ChannelError.decoding(error))
          }
        }
      }
      let rid = request.id
      let fail: @Sendable @MainActor (ChannelError) -> Void = { error in
        guard ch.requests.removeValue(forKey: rid) != nil else { return }
        call.timer?.cancel()
        continuation.resume(throwing: error)
      }
      call.id = connection.send(request, options: RequestOptions(replay: options?.replay ?? true, fail: fail))
      call.startTimer(options?.timeout ?? connection.requestTimeout, rid: rid, connection: connection, fail: fail)
    }
  }
  
  public func values<Body: Encodable, Context: Encodable, Output: Decodable>(_ path: String, _ body: Body?, options: SendOptions<Context>?) -> Values<State, Body, Context, Output> {
    Values(ch: ch, path: path, body: body, options: options, connection: connection)
  }
  
  /// Subscribes to `path`. The response body is delivered to `event` first, as a snapshot, then every published event.
  /// A response without a topic is one-shot: its body is delivered once and the subscription ends.
  /// Active subscriptions are sent again after a reconnect and deliver a fresh snapshot.
  public func subscribe<Body: Encodable & Sendable, Context: Encodable & Sendable>(_ path: String, _ body: Body?, options: SendOptions<Context>?, event: @escaping @Sendable @MainActor (AnyBody) -> Void) async throws -> _Cancellable {
    let ch = self.ch
    let connection = self.connection
    return try await withCheckedThrowingContinuation { continuation in
      let sub = SubscriptionCall(continuation: continuation)
      let request = ch.makeSubscription(path, body, options) { response in
        sub.timer?.cancel()
        sub.timer = nil
        if let error = response.channelError {
          // Refused, on the first try or on a resubscribe after a reconnect: the subscription ends
          sub.cancel(ch: ch, connection: connection)
          sub.resume(throwing: error)
        } else if let topic = response.topic {
          if sub.topic != topic {
            _ = sub.removeTopic?()
            sub.topic = topic
            sub.removeTopic = connection.addTopic(topic: topic, event: event)
          }
          if response.hasBody {
            event(response.anyBody)
          }
          // Only the first response returns a cancellable: releasing one cancels the subscription
          if sub.isWaiting {
            sub.resume(returning: _AnyCancellable(subscription: sub) {
              onMainActor { sub.cancel(ch: ch, connection: connection) }
            })
          }
        } else {
          sub.end(ch: ch, connection: connection)
          if response.hasBody {
            event(response.anyBody)
          }
          if sub.isWaiting {
            sub.resume(returning: _AnyCancellable(subscription: sub) { })
          }
        }
      }
      let rid = request.id
      sub.rid = rid
      // With `replay: false`, a dropped connection ends an active subscription silently
      let fail: @Sendable @MainActor (ChannelError) -> Void = { error in
        sub.cancel(ch: ch, connection: connection)
        sub.resume(throwing: error)
      }
      sub.id = connection.send(request, options: RequestOptions(replay: options?.replay ?? true, fail: fail))
      if let timeout = options?.timeout ?? connection.requestTimeout, timeout > 0 {
        sub.timer = Task { @MainActor in
          try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          guard !Task.isCancelled, sub.isWaiting, let id = sub.id else { return }
          let written = !connection.cancel(id)
          fail(.timeout)
          if written {
            connection.notify(CancellationRequest(cancel: rid))
          }
        }
      }
    }
  }
  
  public func stop() {
    self.connection.stop()
  }
}

// MARK: - Stream
public struct Values<State: Sendable, Body: Encodable & Sendable, Context: Encodable & Sendable, Output: Decodable & Sendable>: AsyncSequence, @unchecked Sendable {
  public typealias Element = Output
  private let ch: Channel<State>
  private let path: String
  private let body: Body?
  private let options: SendOptions<Context>?
  private let connection: ConnectionInterface
  init(ch: Channel<State>, path: String, body: Body?, options: SendOptions<Context>?, connection: ConnectionInterface) {
    self.ch = ch
    self.path = path
    self.body = body
    self.options = options
    self.connection = connection
  }
  public func makeAsyncIterator() -> ValuesIterator<State, Body, Context, Output> {
    ValuesIterator(ch: ch, path: path, body: body, options: options, connection: connection)
  }
}


public class ValuesIterator<State: Sendable, Body: Encodable & Sendable, Context: Encodable & Sendable, Output: Decodable & Sendable>: AsyncIteratorProtocol, @unchecked Sendable {
  public typealias Element = Output
  
  private let ch: Channel<State>
  private let path: String
  private let body: Body?
  private let options: SendOptions<Context>?
  private let connection: ConnectionInterface
  private var isRunning = false
  private var pending: [(@MainActor (Result<Element?, Error>) -> Void)] = []
  private var queued: [Result<Element?, Error>] = []
  private var rid: Int?
  private var isCompleted: Bool = false
  private var connectionRequestId: Int?
  
  init(ch: Channel<State>, path: String, body: Body?, options: SendOptions<Context>?, connection: ConnectionInterface) {
    self.ch = ch
    self.path = path
    self.body = body
    self.options = options
    self.connection = connection
  }
  
  @MainActor
  private func onCancel(id: Int) {
    isCompleted = true
    if let connectionRequestId, !self.connection.cancel(connectionRequestId) {
      _ = self.connection.notify(CancellationRequest(cancel: id))
    }
  }
  
  @MainActor
  private func onComplete() {
    isCompleted = true
    if let connectionRequestId {
      _ = self.connection.cancel(connectionRequestId)
    }
  }
  
  @MainActor
  private func start() {
    if self.isRunning { return }
    self.isRunning = true
    let request = self.ch.makeStream(path, body, options) { response in
      self.deliver(Result<Element?, Error> { try response.parseStream() })
    }
    let rid = request.id
    self.rid = rid
    let ch = self.ch
    connectionRequestId = self.connection.send(request, options: RequestOptions(replay: options?.replay ?? true) { [weak self] error in
      guard ch.requests.removeValue(forKey: rid) != nil else { return }
      self?.deliver(.failure(error))
    })
  }
  
  @MainActor
  private func deliver(_ result: Result<Element?, Error>) {
    if !self.pending.isEmpty {
      let pendingClosure = self.pending.removeFirst()
      pendingClosure(result)
    } else {
      self.queued.append(result)
    }
  }
  
  @MainActor
  public func next() async throws -> Element? {
    do {
      let value = try await _next()
      if value == nil {
        onComplete()
      }
      return value
    } catch {
      onComplete()
      throw error
    }
  }
  @MainActor
  private func _next() async throws -> Element? {
    if !queued.isEmpty {
      return try queued.removeFirst().get()
    } else {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element?, Error>) in
          if self.queued.count > 0 {
            continuation.resume(with: self.queued.removeFirst())
          } else {
            self.pending.append { response in
              guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return }
              continuation.resume(with: response)
            }
            self.start()
          }
        }
      } onCancel: {
        Task { @MainActor in
          if let rid {
            onCancel(id: rid)
          }
        }
      }
    }
  }
  deinit {
    if !isCompleted, let connectionRequestId, let rid {
      let c = connection
      Task { @MainActor in
        if !c.cancel(connectionRequestId) {
          _ = c.notify(CancellationRequest(cancel: rid))
        }
      }
    }
  }
}
private extension ReceivedResponse {
  func parseStream<T: Decodable>() throws -> T? {
    if let error = channelError {
      throw error
    } else if done == true {
      return try? anyBody.body()
    } else {
      do {
        return try anyBody.body()
      } catch {
        throw ChannelError.decoding(error)
      }
    }
  }
}

/// State of one post call: the connection's id for it and its timeout
@MainActor
final class PendingCall: Sendable {
  var id: Int?
  var timer: Task<Void, Never>?
  func finish(_ connection: ConnectionInterface) {
    timer?.cancel()
    timer = nil
    if let id {
      connection.sent(id)
    }
  }
  func startTimer(_ timeout: TimeInterval?, rid: Int, connection: ConnectionInterface, fail: @escaping @Sendable @MainActor (ChannelError) -> Void) {
    guard let timeout, timeout > 0 else { return }
    timer = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      guard !Task.isCancelled, let id = self?.id else { return }
      // `cancel` returns false when the request already went out, then the server gets `{cancel}`
      let written = !connection.cancel(id)
      fail(.timeout)
      if written {
        connection.notify(CancellationRequest(cancel: rid))
      }
    }
  }
}

/// State of one subscription, shared by its response handler and its cancellable
@MainActor
final class SubscriptionCall: Sendable {
  private var continuation: CheckedContinuation<_Cancellable, Error>?
  var id: Int?
  var rid: Int?
  var topic: String?
  var removeTopic: (@Sendable @MainActor () -> Bool)?
  var timer: Task<Void, Never>?
  private(set) var isEnded = false
  var isWaiting: Bool { continuation != nil }
  init(continuation: CheckedContinuation<_Cancellable, Error>) {
    self.continuation = continuation
  }
  func resume(returning value: _Cancellable) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(returning: value)
  }
  func resume(throwing error: Error) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(throwing: error)
  }
  /// Removes the subscription from the response handlers and from the replay set
  func end<State>(ch: Channel<State>, connection: ConnectionInterface) {
    guard !isEnded else { return }
    isEnded = true
    timer?.cancel()
    timer = nil
    if let rid {
      ch.requests[rid] = nil
    }
    if let id {
      connection.sent(id)
    }
  }
  /// Ends the subscription and drops its listener, sending `unsub` when it was the topic's last one
  func cancel<State>(ch: Channel<State>, connection: ConnectionInterface) {
    end(ch: ch, connection: connection)
    if let removeTopic, let topic {
      self.removeTopic = nil
      if removeTopic() {
        connection.notify(["unsub": topic])
      }
    }
  }
}

/// Runs `body` right away on the main thread, otherwise on the main actor later
func onMainActor(_ body: @escaping @Sendable @MainActor () -> Void) {
  if Thread.isMainThread {
    MainActor.assumeIsolated(body)
  } else {
    Task { @MainActor in body() }
  }
}

final class UnsafeMutable<Value: Sendable>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) {
    self.value = value
  }
}

public protocol _Cancellable: Sendable {
  func cancel()
}
@MainActor
public extension _Cancellable {
  /// For a value returned by `subscribe`: the topic the server returned, `nil` for a one-shot subscription
  var topic: String? {
    (self as? _AnyCancellable)?.subscription?.topic
  }
  /// For a value returned by `subscribe`: whether it still gets events and subscribes again after a reconnect.
  /// `false` for a one-shot, after `cancel()`, and once the server refused a resubscribe.
  var isSubscribed: Bool {
    guard let subscription = (self as? _AnyCancellable)?.subscription else { return false }
    return !subscription.isEnded
  }
}
final class _AnyCancellable: _Cancellable {
  private let canceller: @Sendable () -> Void
  let subscription: SubscriptionCall?
  init(subscription: SubscriptionCall? = nil, canceller: @Sendable @escaping () -> Void) {
    self.subscription = subscription
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
private struct CancellationRequest: Encodable {
  var cancel: Int
}
public struct AnyBody: @unchecked Sendable {
  private let container: KeyedDecodingContainer<ReceivedResponse.CodingKeys>
  private let key: ReceivedResponse.CodingKeys
  init(container: KeyedDecodingContainer<ReceivedResponse.CodingKeys>, key: ReceivedResponse.CodingKeys = .body) {
    self.container = container
    self.key = key
  }
  /// Decodes the value. Use an optional type to accept `null` or a missing value.
  public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
    try body()
  }
  /// Same as `decode(_:)`, with the type inferred from the context
  public func body<Body: Decodable>() throws -> Body {
    if let optional = Body.self as? any OptionalDecodable.Type {
      try optional.decode(container, key: key) as! Body
    } else {
      try container.decode(Body.self, forKey: key)
    }
  }
  func context<Body: Decodable>() throws -> Body {
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
