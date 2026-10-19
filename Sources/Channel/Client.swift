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
#if canImport(Network)
import Network
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
    let ws = WebSocketClient(url: url, headers: options.headers, requestTimeout: options.requestTimeout, pingInterval: options.pingInterval, maximumMessageSize: options.maximumMessageSize, reconnectOnNetworkChange: options.reconnectOnNetworkChange)
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
  /// Headers for the WebSocket upgrade, evaluated before every connection attempt
  public var headers: (@MainActor () async -> [String: String])?
  public var onConnect: (@Sendable (ChannelSender<State>) async throws -> Void)?
  /// Default timeout in seconds for every post and subscription response. `nil` waits forever.
  public var requestTimeout: TimeInterval?
  /// Seconds between pings. With no pong within 10 seconds, the client reconnects. 0 disables pings.
  public var pingInterval: TimeInterval
  /// Largest incoming message in bytes
  public var maximumMessageSize: Int
  /// Calls `reconnectNow()` when the network path changes (where the `Network` framework is available)
  public var reconnectOnNetworkChange: Bool
  
  public init(headers: (@MainActor () async -> [String: String])? = nil, onConnect: (@Sendable (ChannelSender<State>) async throws -> Void)? = nil, requestTimeout: TimeInterval? = nil, pingInterval: TimeInterval = 15, maximumMessageSize: Int = 16 << 20, reconnectOnNetworkChange: Bool = true) {
    self.headers = headers
    self.onConnect = onConnect
    self.requestTimeout = requestTimeout
    self.pingInterval = pingInterval
    self.maximumMessageSize = maximumMessageSize
    self.reconnectOnNetworkChange = reconnectOnNetworkChange
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

@MainActor
public extension ClientSender {
  var connectionState: ConnectionState { ws.connectionState }
  /// A new stream of connection states for each access, starting with the current one
  var states: AsyncStream<ConnectionState> { ws.states }
  /// Calls `handler` on every connection state change until the returned value is cancelled or released
  func onStateChange(_ handler: @escaping @MainActor (ConnectionState) -> Void) -> _Cancellable {
    ws.onStateChange(handler)
  }
  /// Resets the backoff and reconnects at once. Call it on network changes and when the app comes to the foreground.
  func reconnectNow() {
    ws.reconnectNow()
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
public enum ConnectionState: Sendable, Hashable {
  case disconnected, connecting, connected
}

public final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, ConnectionInterface, @unchecked Sendable {
  private var id: Int = 0
  private let url: URL
  private var webSocket: URLSessionWebSocketTask?
  var currentTask: URLSessionWebSocketTask? { webSocket }
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
  public private(set) var connectionState: ConnectionState = .disconnected {
    didSet {
      guard connectionState != oldValue else { return }
      isConnected = connectionState == .connected
      for observer in stateObservers.values {
        observer(connectionState)
      }
    }
  }
  private var stateObservers = [Int: @MainActor (ConnectionState) -> Void]()
  private var nextObserverId = 0
  private var headers: (@MainActor () async -> [String: String])?
  public let requestTimeout: TimeInterval?
  /// Seconds between pings, 0 disables them
  public var pingInterval: TimeInterval
  /// Seconds to wait for a pong before reconnecting
  var pongTimeout: TimeInterval = 10
  /// Largest incoming message in bytes
  public var maximumMessageSize: Int
  /// Whether the client reconnects after drops. `stop()` turns it off, `start()` back on.
  public private(set) var isRunning = true
  /// Failed connection attempts since the last open, drives the reconnect backoff
  private var attempts = 0
  /// Bumped on every connection attempt, so a stale header evaluation doesn't open a socket
  private var attempt = 0
  private var reconnectTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var pongTask: Task<Void, Never>?
  private let reconnectOnNetworkChange: Bool
  private var pathMonitor: AnyObject?
  private var lastPath: NetworkPath?
  private let decoderQueue = DispatchQueue(label: "decoder")
  private let encoderQueue = DispatchQueue(label: "encoder")
  
  public init(url: URL, headers: (@MainActor () async -> [String: String])? = nil, requestTimeout: TimeInterval? = nil, pingInterval: TimeInterval = 15, maximumMessageSize: Int = 16 << 20, reconnectOnNetworkChange: Bool = true) {
    self.url = url
    self.headers = headers
    self.requestTimeout = requestTimeout
    self.pingInterval = pingInterval
    self.maximumMessageSize = maximumMessageSize
    self.reconnectOnNetworkChange = reconnectOnNetworkChange
    super.init()
    self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    start()
  }
  
  /// Connects, unless a connection is already open or opening
  public func start() {
    isRunning = true
    startPathMonitor()
    guard webSocket == nil else { return }
    reconnectTask?.cancel()
    reconnectTask = nil
    attempt += 1
    connectionState = .connecting
    if let headers {
      let attempt = self.attempt
      Task { @MainActor in
        let fields = await headers()
        guard self.attempt == attempt, self.isRunning, self.webSocket == nil else { return }
        self.open(headers: fields)
      }
    } else {
      open(headers: [:])
    }
  }
  
  private func open(headers: [String: String]) {
    var request = URLRequest(url: url)
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let webSocket = session.webSocketTask(with: request)
    webSocket.maximumMessageSize = maximumMessageSize
    self.webSocket = webSocket
    webSocket.resume()
    receiveMessage(webSocket)
  }
  
  private func receiveMessage(_ task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      guard let self else { return }
      Task { @MainActor in
        switch result {
        case .success(let message):
          switch message {
          case .string(let text):
            self.received(text: text, from: task)
          default: break // Binary frames are ignored
          }
          // Continue receiving messages
          self.receiveMessage(task)
        case .failure:
          self.connectionLost(task)
        }
      }
    }
  }
  
  func received(text: String, from task: URLSessionWebSocketTask?) {
    let data = Data(text.utf8)
    if debug { print("ws:", text) }
    decoderQueue.async {
      do {
        let array = try JSONDecoder.iso8601.decode(DecodableArray<ReceivedResponse>.self, from: data).array
        DispatchQueue.main.async {
          self.onMessage?(array)
        }
      } catch {
        // A frame that isn't JSON closes the connection, valid JSON that isn't a message is ignored
        let isJSON = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
        DispatchQueue.main.async {
          if self.debug { print("ws: dropped frame:", error) }
          if !isJSON {
            self.connectionLost(task ?? self.webSocket)
          }
        }
      }
    }
  }
  
  /// Closes the current connection, fails pending calls that can't be replayed and schedules a reconnect
  func connectionLost(_ task: URLSessionWebSocketTask?) {
    guard let task, task === webSocket else { return }
    webSocket = nil
    task.cancel(with: .goingAway, reason: nil)
    stopPing()
    messageQueue.removeAll()
    isWaiting = 0
    connectionState = .disconnected
    for entry in pending.dropped() {
      entry.fail?(.disconnected)
    }
    scheduleReconnect()
  }
  
  /// Retries after 100 ms, doubling up to 5 s while the server stays down, each delay randomized to 50-100%
  static func reconnectDelay(attempts: Int, random: Double = .random(in: 0...1)) -> TimeInterval {
    min(5, 0.1 * pow(2, Double(min(attempts, 16)))) * (0.5 + random / 2)
  }
  
  private func scheduleReconnect() {
    guard isRunning else { return }
    let delay = WebSocketClient.reconnectDelay(attempts: attempts)
    attempts += 1
    reconnectTask?.cancel()
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self, self.isRunning else { return }
      self.reconnectTask = nil
      self.start()
    }
  }
  
  /// Resets the backoff and tries at once: a closed connection reconnects, one that is opening starts over,
  /// and an open one is checked with a ping.
  public func reconnectNow() {
    guard isRunning else { return }
    attempts = 0
    switch connectionState {
    case .connected:
      if let webSocket {
        ping(webSocket)
      }
    case .connecting:
      let task = webSocket
      webSocket = nil
      task?.cancel(with: .goingAway, reason: nil)
      connectionState = .disconnected
      start()
    case .disconnected:
      start()
    }
  }
  
  /// Stops reconnecting, closes the connection and fails every pending call with `disconnected`
  public func stop() {
    isRunning = false
    reconnectTask?.cancel()
    reconnectTask = nil
    stopPing()
    stopPathMonitor()
    let task = webSocket
    webSocket = nil
    task?.cancel(with: .goingAway, reason: nil)
    messageQueue.removeAll()
    isWaiting = 0
    connectionState = .disconnected
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
    let encodable = AnyEncodable(body: body)
    pending.add(id, PendingQueue.Entry(body: encodable, replay: options.replay, written: isConnected, fail: options.fail))
    
    guard isConnected else { return id }
    
    switch isWaiting {
    case 0:
      trySend(encodable)
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
      trySend(encodable)
      isWaitingLength += 1
    case 2:
      messageQueue.append(encodable)
    case 3:
      trySend(encodable)
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
  
  // MARK: Connection state
  
  /// A new stream of connection states for each access, starting with the current one
  public var states: AsyncStream<ConnectionState> {
    AsyncStream { continuation in
      continuation.yield(connectionState)
      let id = addStateObserver { continuation.yield($0) }
      continuation.onTermination = { [weak self] _ in
        onMainActor { self?.stateObservers[id] = nil }
      }
    }
  }
  
  /// Calls `handler` on every connection state change until the returned value is cancelled or released
  public func onStateChange(_ handler: @escaping @MainActor (ConnectionState) -> Void) -> _Cancellable {
    let id = addStateObserver(handler)
    return _AnyCancellable { [weak self] in
      onMainActor { self?.stateObservers[id] = nil }
    }
  }
  
  private func addStateObserver(_ handler: @escaping @MainActor (ConnectionState) -> Void) -> Int {
    let id = nextObserverId
    nextObserverId += 1
    stateObservers[id] = handler
    return id
  }
  
  // MARK: Liveness
  
  private func startPing() {
    stopPing()
    let interval = pingInterval
    guard interval > 0 else { return }
    pingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled, let self, let task = self.webSocket, self.isConnected else { return }
        self.ping(task)
      }
    }
  }
  
  private func stopPing() {
    pingTask?.cancel()
    pingTask = nil
    pongTask?.cancel()
    pongTask = nil
  }
  
  /// Sends a ping. With no pong within `pongTimeout`, the connection is closed and reconnects.
  private func ping(_ task: URLSessionWebSocketTask) {
    guard pongTask == nil else { return }
    let timeout = pongTimeout
    pongTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.pongTask = nil
      if self.debug { print("ws: no pong") }
      self.connectionLost(task)
    }
    task.sendPing { [weak self] error in
      Task { @MainActor in
        guard let self, task === self.webSocket else { return }
        self.pongTask?.cancel()
        self.pongTask = nil
        if error != nil {
          self.connectionLost(task)
        }
      }
    }
  }
  
  // MARK: Network changes
  
  private func startPathMonitor() {
    #if canImport(Network)
    guard reconnectOnNetworkChange, pathMonitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let key = NetworkPath(path)
      Task { @MainActor in
        self?.pathChanged(key)
      }
    }
    monitor.start(queue: DispatchQueue(label: "channel.network"))
    pathMonitor = monitor
    #endif
  }
  
  private func stopPathMonitor() {
    #if canImport(Network)
    (pathMonitor as? NWPathMonitor)?.cancel()
    #endif
    pathMonitor = nil
    lastPath = nil
  }
  
  func pathChanged(_ path: NetworkPath) {
    defer { lastPath = path }
    guard let lastPath, lastPath != path, path.isSatisfied else { return }
    if debug { print("ws: network changed") }
    reconnectNow()
  }
  
  // MARK: URLSessionWebSocketDelegate
  
  nonisolated public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    Task { @MainActor in
      guard webSocketTask === webSocket else { return }
      attempts = 0
      connectionState = .connected
      // Unanswered requests go out again in their original order
      let bodies = pending.flush()
      if !bodies.isEmpty {
        trySend(bodies)
      }
      startPing()
      onOpen?()
    }
  }
  
  nonisolated public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    Task { @MainActor in
      connectionLost(webSocketTask)
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

/// Network path fields that matter for an open connection
struct NetworkPath: Hashable, Sendable {
  var isSatisfied: Bool
  var interfaces: [String]
  #if canImport(Network)
  init(_ path: NWPath) {
    isSatisfied = path.status == .satisfied
    interfaces = path.availableInterfaces.map(\.name)
  }
  #endif
  init(isSatisfied: Bool, interfaces: [String]) {
    self.isSatisfied = isSatisfied
    self.interfaces = interfaces
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
