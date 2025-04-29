//
//  File.swift
//  ChannelSwift
//
//  Created by Dmitry Kozlov on 23/4/25.
//

import Foundation
import Combine

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
    let ws = WebSocketClient(url: url, headers: options.headers)
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
  
  public init(headers: (() -> [String: String])? = nil, onConnect: (@Sendable (ChannelSender<State>) async throws -> Void)? = nil) {
    self.headers = headers
    self.onConnect = onConnect
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
  
  let respond: @Sendable (Encodable & Sendable) -> Void
  let subscribe: @Sendable (String) -> Void
  let unsubscribe: @Sendable (String) -> Void
  let event: @Sendable (String, AnyBody) -> Void
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
  
  private var pending = [Int: AnyEncodable]()
  private var isWaiting = 0
  private var isWaitingLength = 0
  private var messageQueue = [AnyEncodable]()
  @Published public private(set) var isConnected = false
  private var headers: (() -> [String: String])?
  private var reconnectTimer: Timer?
  private let decoderQueue = DispatchQueue(label: "decoder")
  private let encoderQueue = DispatchQueue(label: "encoder")
  
  public init(url: URL, headers: (() -> [String: String])? = nil) {
    self.url = url
    self.headers = headers
    super.init()
    self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    start()
  }
  
  public func start() {
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
      switch result {
      case .success(let message):
        switch message {
        case .string(let text):
          guard let data = text.data(using: .utf8) else { return }
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
        self.handleDisconnection()
      }
    }
  }
  
  private func handleDisconnection() {
    isConnected = false
    webSocket = nil
    
    // Schedule reconnection
    DispatchQueue.main.async {
      self.reconnectTimer?.invalidate()
      self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
        self?.start()
      }
    }
  }
  
  public func stop() {
    pending.removeAll()
    webSocket?.cancel(with: .goingAway, reason: nil)
    reconnectTimer?.invalidate()
  }
  
  @discardableResult
  public func send<Body: Encodable & Sendable>(_ body: Body) -> Int {
    let id = self.id
    self.id += 1
    pending[id] = AnyEncodable(body: body)
    
    if webSocket == nil {
      return id
    }
    
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
      messageQueue.append(AnyEncodable(body: body))
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
    encoderQueue.async {
      guard let string = try? String(data: JSONEncoder.iso8601.encode(encodable), encoding: .utf8) else { return }
      webSocket.send(.string(string)) { _ in }
    }
  }
  
  public func cancel(_ id: Int) -> Bool {
    if isConnected { return false }
    if pending[id] == nil { return false }
    pending.removeValue(forKey: id)
    return true
  }
  
  public func notify<Body: Encodable & Sendable>(_ body: Body) {
    trySend(body)
  }
  
  public func sent(_ id: Int) {
    pending.removeValue(forKey: id)
  }
  
  public func throttle() {
    isWaiting = 3
  }
  
  public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    isConnected = true
    if !pending.isEmpty {
      send(Array(pending.values))
    }
    DispatchQueue.main.async { [weak self] in
      self?.onOpen?()
    }
  }
  
  public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    handleDisconnection()
  }
  private struct AnyEncodable: Encodable, @unchecked Sendable {
    let body: Encodable
    func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(body)
    }
  }
  private var subscribed = [String: [Int: (AnyBody) -> Void]]()
  private var nextEventId = 0
  
  public func addTopic(topic: String, event: @escaping (AnyBody) -> Void) -> @Sendable () -> Bool {
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


extension JSONDecoder {
  @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
  static let formatter = Date.ISO8601FormatStyle().dateSeparator(.dash).time(includingFractionalSeconds: true)
  struct InvalidDateFormat: Error { }
  static let iso8601: JSONDecoder = {
    let decoder = JSONDecoder()
    if #available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
      decoder.dateDecodingStrategy = .custom {
        let string = try $0.singleValueContainer().decode(String.self)
        return try Date.init(string, strategy: formatter)
      }
    }
    return decoder
  }()
}
extension JSONEncoder {
  static let iso8601: JSONEncoder = {
    let encoder = JSONEncoder()
    if #available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
      encoder.dateEncodingStrategy = .custom { date, encoder in
        try JSONDecoder.formatter.format(date).encode(to: encoder)
      }
    }
    return encoder
  }()
}
