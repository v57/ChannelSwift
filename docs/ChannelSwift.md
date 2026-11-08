# ChannelSwift

## Purpose

ChannelSwift is the Swift port of [Channel](https://github.com/v57/channel), a small JSON protocol for requests,
streams and subscriptions. The SwiftPM product is `Channel` (`import Channel`). It is a **client**: it connects to a
Channel server over WebSocket (`ws://`, `wss://`) or, on Apple platforms, QUIC (`quic://`), reconnects on its own and
uses async/await and `AsyncSequence`. The protocol is symmetric, so the same `Channel` also answers calls the server
makes back over that connection (handlers registered with `post` and `stream`).

It is what HubService's Swift SDK and the Hub apps talk to hubs with. It is not a server: it doesn't listen for
connections. The Swift server is `ChannelServer` in [HubServer](https://github.com/v57/HubServer), a separate
library with the same protocol. It has no in-process transport either.

The TypeScript library is the protocol's source of truth; the wire format is described there
([structure.md](https://github.com/v57/channel/blob/main/docs/structure.md),
[v2.md](https://github.com/v57/channel/blob/main/docs/v2.md),
[quic.md](https://github.com/v57/channel/blob/main/docs/quic.md)), and
[ports.md](https://github.com/v57/channel/blob/main/docs/ports.md) compares this port with the others. The
[README](../README.md) has more examples for connection options, request options, errors and subscriptions.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/ChannelSwift.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "Channel", package: "ChannelSwift")]),
]
```

The package uses Swift tools 6.1. On Linux, `wss://` needs OpenSSL's headers (`apt install libssl-dev`).

### A client

Calls go through `@MainActor` methods, so call them from the main actor.

```swift
import Foundation
import Channel

struct Room: Codable, Sendable { var room: String }

@MainActor
func run() async throws {
  let client = Channel<Void>().connect(URL(string: "wss://hub.example.com/ws")!, options: ClientOptions(
    headers: { ["authorization": "Bearer token"] }, // evaluated before every connection attempt
    requestTimeout: 30
  ))

  // A request: the reply decodes into the type you ask for
  let greeting: String = try await client.send("hello")
  let sum: Int = try await client.send("add", [1, 2])

  // A stream: leaving the loop early cancels it on the server
  for try await value in client.values("count", as: Int.self) {
    print(value)
  }

  // A subscription: the server's snapshot first, then published events
  let subscription = try await client.subscribe("room", Room(room: "lobby")) { body in
    if let text = try? body.decode(String.self) { print(text) }
  }
  subscription.cancel()

  client.stop() // stops reconnecting and fails pending calls with `disconnected`
}
```

`connect(2049)` is a shortcut for `ws://127.0.0.1:2049`.

### Answering the server

Handlers on the `Channel` answer requests the server sends over the client's connection, for example a hub calling
a service it holds the connection of.

```swift
struct Greeting: Codable, Sendable { var name: String }
struct Session: Sendable { var user: String }

let channel = Channel<Session>()
  .post("app/version") { "1.0" }
  .post("app/greet") { (request: Greeting) in "Hello, \(request.name)" }
  // With the connection's state, the request context and the sender. Use an optional type for the context.
  .post("app/whoami") { (request: Body<EmptyCodable?, EmptyCodable?, Session>) in request.state.user }
  // A stream ends when the closure returns, or with the error it throws
  .stream("app/count") { continuation in
    for i in 0..<3 { continuation.yield(i) }
  }

let client = channel.connect(URL(string: "ws://127.0.0.1:1997")!, state: Session(user: "user"))
```

A thrown `ChannelError` reaches the caller with its text, `code` and `info`; any other error reaches it as
`internal error`, so its details stay on this side. A path with no handler answers `api not found` with code
`not_found`.

## Main API

### Channel

| API | What |
| --- | --- |
| `Channel<State>()` | A channel. `State` is what handlers see as `state`; `Void` when there is none. |
| `post(_:request:)` | A request handler. The closure takes nothing, the decoded body, or `Body<Input, Context, State>`; it returns a value or nothing. |
| `stream(_:request:)` | A stream handler. The closure gets an `AsyncThrowingStream` continuation (and optionally the body as `Body<Input, Context, State>`) and yields values. |
| `postOther(_:request:)`, `streamOther(_:request:)` | Handlers for every path a predicate accepts, checked after the exact paths. |
| `events(_:prefix:)` | Subscriptions this side answers, as `Subscription(topic:body:)` values: the reply carries the topic and a snapshot. Publishing to them doesn't reach a client connection yet. |
| `connect(_:options:)`, `connect(_:state:options:)` | Connects to a port on 127.0.0.1 or a `ws://`, `wss://` or `quic://` URL; returns a `ClientSender`. |

### Calls (`ClientSender`, any `Sender`)

| API | What |
| --- | --- |
| `send(_:)`, `send(_:_:)`, `send(_:_:options:)` | A request. The reply decodes into the result type; `Void` versions ignore it. |
| `values(_:_:)`, `values(_:as:)`, `values(_:_:options:)` | A stream, as an `AsyncSequence` (`Values`). Breaking out of the loop cancels it. |
| `subscribe(_:_:event:)`, `subscribe(_:_:options:event:)` | A subscription. Resolves once the server answered and the snapshot was delivered; returns a `_Cancellable` with `cancel()`, `topic` (`nil` for a one-shot) and `isSubscribed`. |
| `stop()` | Stops reconnecting, closes the connection, fails every pending call with `disconnected`. |
| `SendOptions(context:timeout:replay:)` | Per call: a context sent next to the body, a timeout in seconds (fails with `timeout` and cancels the call on the server), and whether to send the call again after a reconnect (`replay`, default `true`). |

`AnyBody` is an undecoded value, as event handlers and `Body.body` of untyped handlers get it: `decode(_:)`,
`body()`, `context(_:)`, and `isSnapshot` (the subscription response's body, as opposed to a published event).
`EmptyCodable` stands for "no value".

### Connection

| API | What |
| --- | --- |
| `ClientOptions(headers:onConnect:requestTimeout:pingInterval:maximumMessageSize:reconnectOnNetworkChange:alternateURLs:openTimeout:quic:)` | Connect options: upgrade headers (async, evaluated per attempt), a callback on every connection, the default call timeout, pings (15 s, 0 disables), the largest incoming message (16 MiB), reconnecting on network changes, other addresses of the same server, and QUIC trust. |
| `QUICOptions(ca:fingerprint:serverName:)` | Trust for `quic://`: a CA or self-signed certificate, a pinned SHA-256 fingerprint, or the name to check. |
| `connectionState`, `states`, `onStateChange(_:)` | `.disconnected`, `.connecting` or `.connected`; a stream of changes; a callback until the returned value is cancelled or released. |
| `reconnectNow()` | Skips the backoff, for example when the app comes to the foreground. |
| `refusal` | Set while the server refuses the connection (`ConnectionRefusal`, its HTTP status). Posts fail with `refused` then. |
| `ws` | The `WebSocketClient` underneath: `start()` after `stop()`, `reconnect()` (fresh headers), `refuseConnecting(_:)` (from `headers`, refuse an attempt without opening anything), `nextURL` (from `headers`, pick the address of this attempt), `currentURL`, `onRefused`, `refusedRetryDelay`, `isConnectedChanged`, `debug`. |

### Errors

Calls throw `ChannelError`: `text` (the message), `code` (`ChannelError.Code?`, `.int` or `.string`, comparable with
literals) and `info` (`AnyBody?`, any JSON). Library codes: `.notFound`, `.cancelled`, `.rateLimited`, and on the
client `.timeout`, `.disconnected`, `.refused` and `.decoding` (the reply didn't decode; only that call fails).

### Behaviour worth knowing

- Reconnect backs off from 100 ms to 5 s with jitter. Unanswered requests are sent again in order, and active
  subscriptions subscribe again and get a fresh snapshot. Events published while disconnected are lost.
- A response answers a request only when it arrives on the connection the request went to. A channel connected to
  several servers ignores one server's replies to calls it sent another.
- A text frame that isn't JSON closes the connection and reconnects. Binary frames are ignored.

## Platform notes

| Platform | Status |
| --- | --- |
| macOS 10.15+, iOS 13+ (iPadOS), tvOS 13+, watchOS 6+, visionOS 1+, Mac Catalyst 13+ | Supported (`Package.swift` platforms). WebSocket on `URLSession`. QUIC needs macOS 12, iOS 15, tvOS 15 or watchOS 8 (Network.framework); reconnect on network changes uses `Network`'s path monitor. |
| Linux | Supported. `ws://` and `wss://` run on the package's own RFC 6455 client over a socket, since `URLSession`'s WebSocket task needs a libcurl built with WebSockets (Ubuntu 24.04's isn't). `wss://` uses OpenSSL (`libssl-dev`): the system's roots or `SSL_CERT_FILE`, host name checks, SNI, TLS 1.2+. No QUIC: a `quic://` address doesn't connect. |
| Windows | Not tested. There is no socket client for it, so WebSocket goes through swift-corelibs-foundation's `URLSession`, which needs a libcurl with WebSockets. No QUIC. |
| Android | Not tested. Same as Windows: `URLSession` from swift-corelibs-foundation, no QUIC. |

## Testing

```bash
swift test                    # everything; see below for what each suite needs
swift test --filter UnitTests # the unit tests, no server needed
```

- `UnitTests`: the channel against a fake connection; needs nothing.
- `WireV2Tests`: start `Tests/Fixture/server.ts`, a Bun fixture with the reference's v2 routes, on port 2051.
  `CHANNEL_FIXTURE_PORT=2049` runs them against the TypeScript reference fixture instead. Needs Bun.
- `Tests.swift`: the older tests, against the TypeScript reference fixture on 2049. Start it in a checkout of
  [channel](https://github.com/v57/channel) with `bun tests/server.ts`.
- `QUICTests`: start the reference fixture from `../channel` (a checkout next to this one) on 2053 and 2054, with a
  certificate made by `/usr/bin/openssl` for the run. They run on macOS, and are skipped when `../channel` isn't there.
- `SocketWebSocketTests`: the Linux socket client; the `wss://` checks run only when `CHANNEL_WSS_URL`,
  `CHANNEL_WSS_MISMATCH_URL` and `CHANNEL_WS_BAD_ACCEPT_URL` point at `Tests/Fixture/ws-proxy.py` in front of a
  fixture (the file's header comment has the commands).

The package offers no fakes to apps. `ConnectionInterface` is public, so a test can drive a `Channel` through its
own connection and `receive(_:controller:)`, as `UnitTests` does with its `FakeConnection`.
