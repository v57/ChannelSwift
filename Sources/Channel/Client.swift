//
//  File.swift
//  ChannelSwift
//
//  Created by Dmitry Kozlov on 23/4/25.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension Channel {
  func connect(_ port: Int, state: State, options: ClientOptions<State> = ClientOptions()) -> ClientSender<State> {
    connect(URL(string: "ws://127.0.0.1:\(port)")!, state: state, options: options)
  }
  func connect(_ port: Int, options: ClientOptions<State> = ClientOptions()) -> ClientSender<State> where State == Void {
    connect(port, state: (), options: options)
  }
  func connect(_ url: URL, options: ClientOptions<State> = ClientOptions()) -> ClientSender<State> where State == Void {
    connect(url, state: (), options: options)
  }
  func connect(_ url: URL, state: State, options: ClientOptions<State> = ClientOptions()) -> ClientSender<State> {
    let ch = self
    let ws = WebSocketClient(url: url, headers: options.headers, requestTimeout: options.requestTimeout)
    let topics = UnsafeMutable(Set<String>())
    let sender = ChannelSender(ch: ch, connection: ws)
    
    // Setup connection callbacks
    if let onConnect = options.onConnect {
      ws.onOpen = {
        Task {
          try? await onConnect(sender)
        }
      }
    }
    
    ws.onMessage = { message in
      ch.receive(message, controller: ChannelController(
        respond: { body in
          ws.notify(body)
        },
        subscribe: { topic in
          topics.value.insert(topic)
        },
        unsubscribe: { topic in
          topics.value.remove(topic)
        },
        event: { topic, body in
          ws.receivedEvent(topic: topic, body: body)
        },
        sender: sender,
        state: state
      ))
    }
    
    // Connect subscription publishers
    /*
    self.eventsApi?.forEach { key, subscription in
      subscription.publishers.append(SubscriptionPublisher { event in
        guard topics.contains(event.topic) else { return }
        ws.send(event)
      })
    }
    */
    return ClientSender(sender: sender, ws: ws)
  }
}

// MARK: - ClientOptions

public struct ClientOptions<State: Sendable> {
  public var headers: (() -> [String: String])?
  public var onConnect: (@Sendable (ChannelSender<State>) async throws -> Void)?
  /// Default timeout in seconds for every post and subscription response. `nil` waits forever.
  public var requestTimeout: TimeInterval?
  
  public init(headers: (() -> [String: String])? = nil, onConnect: (@Sendable (ChannelSender<State>) async throws -> Void)? = nil, requestTimeout: TimeInterval? = nil) {
    self.headers = headers
    self.onConnect = onConnect
    self.requestTimeout = requestTimeout
  }
}

// MARK: - ClientSender

public struct ClientSender<State: Sendable>: ProxySender {
  public let sender: ChannelSender<State>
  public let ws: WebSocketClient
  
  init(sender: ChannelSender<State>, ws: WebSocketClient) {
    self.sender = sender
    self.ws = ws
  }
}

// MARK: - ChannelController

private struct ChannelController<State: Sendable>: Controller {
  func respond(_ response: Encodable & Sendable) {
    self.respond(response)
  }
  
  func subscribe(_ topic: String) {
    self.subscribe(topic)
  }
  
  func unsubscribe(_ topic: String) {
    self.unsubscribe(topic)
  }
  
  func event(_ topic: String, _ event: AnyBody) {
    self.event(topic, event)
  }
  
  let respond: @Sendable @MainActor (Encodable & Sendable) -> Void
  let subscribe: @Sendable @MainActor (String) -> Void
  let unsubscribe: @Sendable @MainActor (String) -> Void
  let event: @Sendable @MainActor (String, AnyBody) -> Void
  let sender: any Sender
  let state: State
}

// MARK: - WebSocketClient
public final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, ConnectionInterface, @unchecked Sendable {
  private var id: Int = 0
  private let url: URL
  private var webSocket: URLSessionWebSocketTask?
  private var session: URLSession!
  
  public var onOpen: (() -> Void)?
  public var onMessage: (([ReceivedResponse]) -> Void)?
  public var debug: Bool = false
  public var pendingCount: Int { pending.count }
  private var pending = PendingQueue()
  private var isWaiting = 0
  private var isWaitingLength = 0
  private var messageQueue = [AnyEncodable]()
  public private(set) var isConnected = false {
    didSet {
      guard isConnected != oldValue else { return }
      isConnectedChanged?(isConnected)
    }
  }
  public var isConnectedChanged: ((Bool) -> ())?
  private var headers: (() -> [String: String])?
  public let requestTimeout: TimeInterval?
  /// Whether the client reconnects after drops. `stop()` turns it off, `start()` back on.
  public private(set) var isRunning = true
  private var reconnectTimer: Timer?
  private let decoderQueue = DispatchQueue(label: "decoder")
  private let encoderQueue = DispatchQueue(label: "encoder")
  
  public init(url: URL, headers: (() -> [String: String])? = nil, requestTimeout: TimeInterval? = nil) {
    self.url = url
    self.headers = headers
    self.requestTimeout = requestTimeout
    super.init()
    self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    start()
  }
  
  public func start() {
    isRunning = true
    var request = URLRequest(url: url)
    if let headerProvider = headers {
      let headerFields = headerProvider()
      for (key, value) in headerFields {
        request.setValue(value, forHTTPHeaderField: key)
      }
    }
    
    let webSocket = session.webSocketTask(with: request)
    self.webSocket = webSocket
    
    webSocket.resume()
    receiveMessage()
  }
  
  private func receiveMessage() {
    webSocket?.receive { [weak self] result in
      guard let self else { return }
      Task { @MainActor in
        switch result {
        case .success(let message):
          switch message {
          case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            if debug { print("ws:", text) }
            decoderQueue.async {
              do {
                let array = try JSONDecoder.iso8601.decode(DecodableArray<ReceivedResponse>.self, from: data).array
                DispatchQueue.main.async {
                  self.onMessage?(array)
                }
              } catch { }
            }
          default: break
          }
          // Continue receiving messages
          self.receiveMessage()
        case .failure:
          self.disconnected()
        }
      }
    }
  }
  
  private func disconnected() {
    isConnected = false
    webSocket = nil
    messageQueue.removeAll()
    isWaiting = 0
    for entry in pending.dropped() {
      entry.fail?(.disconnected)
    }
    guard isRunning else { return }
    
    // Schedule reconnection
    DispatchQueue.main.async {
      self.reconnectTimer?.invalidate()
      self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
        Task { @MainActor in
          self?.start()
        }
      }
    }
  }
  
  /// Stops reconnecting, closes the connection and fails every pending call with `disconnected`
  public func stop() {
    isRunning = false
    webSocket?.cancel(with: .goingAway, reason: nil)
    reconnectTimer?.invalidate()
    for entry in pending.removeAll() {
      entry.fail?(.disconnected)
    }
  }
  
  @discardableResult
  public func send<Body: Encodable & Sendable>(_ body: Body) -> Int {
    send(body, options: RequestOptions())
  }
  
  @discardableResult
  public func send<Body: Encodable>(_ body: Body, options: RequestOptions) -> Int {
    let id = self.id
    self.id += 1
    let body = AnyEncodable(body: body)
    pending.add(id, PendingQueue.Entry(body: body, replay: options.replay, written: isConnected, fail: options.fail))
    
    guard isConnected else { return id }
    
    switch isWaiting {
    case 0:
      trySend(body)
      isWaiting = 1
      isWaitingLength = 0
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
        guard let self else { return }
        if isWaitingLength > 1000 {
          isWaiting = 3
        } else {
          isWaiting = 0
        }
      }
    case 1:
      trySend(body)
      isWaitingLength += 1
    case 2:
      messageQueue.append(body)
    case 3:
      trySend(body)
      isWaiting = 2
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
        guard let self else { return }
        self.isWaiting = 3
        if !self.messageQueue.isEmpty {
          trySend(messageQueue)
          self.messageQueue.removeAll(keepingCapacity: true)
        }
      }
    default: break
    }
    
    return id
  }
  
  private func trySend<Body: Encodable & Sendable>(_ encodable: Body) {
    guard isConnected else { return }
    guard let webSocket else { return }
    let debug = self.debug
    encoderQueue.async {
      guard let string = try? String(data: JSONEncoder.iso8601.encode(encodable), encoding: .utf8) else { return }
      if debug {
        print("me:", string)
      }
      webSocket.send(.string(string)) { _ in }
    }
  }
  
  public func cancel(_ id: Int) -> Bool {
    pending.remove(id) != nil && !isConnected
  }
  
  public func notify<Body: Encodable & Sendable>(_ body: Body) {
    trySend(body)
  }
  
  public func sent(_ id: Int) {
    pending.remove(id)
  }
  
  public func throttle() {
    isWaiting = 3
  }
  
  nonisolated public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    Task { @MainActor in
      isConnected = true
      // Unanswered requests go out again in their original order
      let bodies = pending.flush()
      if !bodies.isEmpty {
        trySend(bodies)
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.onOpen?()
    }
  }
  
  nonisolated public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    Task { @MainActor in
      disconnected()
    }
  }
  private var subscribed = [String: [Int: @MainActor (AnyBody) -> Void]]()
  private var nextEventId = 0
  
  public func addTopic(topic: String, event: @escaping @Sendable @MainActor (AnyBody) -> Void) -> @Sendable @MainActor () -> Bool {
    let id = nextEventId
    nextEventId += 1
    
    if var handlers = subscribed[topic] {
      handlers[id] = event
      subscribed[topic] = handlers
    } else {
      subscribed[topic] = [id: event]
    }
    
    return {
      if var handlers = self.subscribed[topic] {
        handlers.removeValue(forKey: id)
        if handlers.isEmpty {
          self.subscribed.removeValue(forKey: topic)
          return true
        } else {
          self.subscribed[topic] = handlers
        }
      }
      return false
    }
  }
  
  public func receivedEvent(topic: String, body: AnyBody) {
    if let handlers = subscribed[topic] {
      for (_, handler) in handlers {
        handler(body)
      }
    }
  }
}

struct AnyEncodable: Encodable, @unchecked Sendable {
  let body: Encodable
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(body)
  }
}

/// Requests waiting for a response, kept for replay after a reconnect
struct PendingQueue {
  struct Entry {
    var body: AnyEncodable
    var replay: Bool
    /// Went out on the current connection
    var written: Bool
    var fail: (@Sendable @MainActor (ChannelError) -> Void)?
  }
  private var entries = [Int: Entry]()
  var count: Int { entries.count }
  var isEmpty: Bool { entries.isEmpty }
  mutating func add(_ id: Int, _ entry: Entry) {
    entries[id] = entry
  }
  @discardableResult
  mutating func remove(_ id: Int) -> Entry? {
    entries.removeValue(forKey: id)
  }
  /// Bodies in their original order (ids only grow), marked as written
  mutating func flush() -> [AnyEncodable] {
    entries.keys.sorted().map { id in
      entries[id]!.written = true
      return entries[id]!.body
    }
  }
  /// The connection dropped: removes and returns the written requests that can't be replayed
  mutating func dropped() -> [Entry] {
    var failed = [Entry]()
    for id in entries.keys.sorted() {
      guard let entry = entries[id], entry.written else { continue }
      if entry.replay {
        entries[id]!.written = false
      } else {
        entries[id] = nil
        failed.append(entry)
      }
    }
    return failed
  }
  mutating func removeAll() -> [Entry] {
    let all = entries.keys.sorted().map { entries[$0]! }
    entries.removeAll()
    return all
  }
}


public extension JSONDecoder {
  struct InvalidDateFormat: Error { }
  static let iso8601: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom {
      let string = try $0.singleValueContainer().decode(String.self)
      guard let date = JSONDecoder.formatter.date(from: string)
        else { throw InvalidDateFormat() }
      return date
    }
    return decoder
  }()
  nonisolated(unsafe) fileprivate static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [
      .withFullDate, .withFullTime,
      .withDashSeparatorInDate, .withFractionalSeconds
    ]
    return formatter
  }()
}
extension JSONEncoder {
  static let iso8601: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      try JSONDecoder.formatter.string(from: date).encode(to: encoder)
    }
    return encoder
  }()
}
