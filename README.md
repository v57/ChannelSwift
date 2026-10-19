<h1>
  <img alt="Containerization logo" src="./icon.png" width="70" valign="middle">
  &nbsp;channel
</h1>

Powerful and lightweight communication built for modern language. Websocket client included. Works on the latest async/await model with AsyncIteratorProtocol support for streaming data

# Usage

```swift
import Channel

// Connect
let channel = Channel().connect(2048)

// Single request
let response: String = try await channel.send("test/echo", "Hello")

// Stream realtime data
for try await name: String in client.values("users/name", "someone") {
  print(name)
}
```

## Connecting

```swift
let client = Channel<Void>().connect(URL(string: "wss://example.com/ws")!, options: ClientOptions(
  // Evaluated before every connection attempt. Sync closures work too.
  headers: { ["authorization": "Bearer \(await tokens.current())"] },
  onConnect: { sender in try await sender.send("hello") },
  requestTimeout: 30,       // default timeout for every call, nil waits forever (default)
  pingInterval: 15,         // seconds between pings, no pong within 10 s reconnects, 0 disables
  maximumMessageSize: 16 << 20,
  reconnectOnNetworkChange: true // calls reconnectNow() when the network path changes (Apple platforms)
))
```

The client reconnects on its own, backing off from 100 ms to 5 s with jitter. Unanswered requests are sent again in
their original order once the connection opens, and active subscriptions subscribe again.

```swift
client.reconnectNow()          // skip the backoff, e.g. when the app comes to the foreground
client.stop()                  // stop reconnecting, fail every pending call with `disconnected`, release the URLSession
client.ws.start()              // connect again after stop()

client.connectionState         // .disconnected, .connecting or .connected
for await state in client.states { }      // one stream per observer, starts with the current state
let observer = client.onStateChange { state in } // keep it, releasing it stops the callbacks
client.ws.isConnectedChanged = { isConnected in } // the old single callback still works
```

A text frame that isn't JSON closes the connection and reconnects, replayable calls survive it. Binary frames are
ignored.

## Request options

```swift
// Fails with code `timeout` after 5 s, and tells the server to cancel the call
let user: User = try await client.send("user/get", id, options: SendOptions(timeout: 5))

// Not idempotent: when the connection drops after the request went out, fail with `disconnected`
// instead of sending it again. A request made while offline is still sent once the connection opens.
try await client.send("payment/create", payment, options: SendOptions(replay: false))

// With a context
try await client.send("chat/send", message, options: SendOptions(context: meta, timeout: 10, replay: false))
```

`timeout` applies to posts and subscription responses, not to stream values. `replay` defaults to `true`.

## Errors

Calls throw `ChannelError`:

```swift
do {
  try await client.send("chat/delete", id)
} catch let error as ChannelError {
  error.text                 // the message, also `description`
  error.code                 // ChannelError.Code?: .int(403) or .string("rate_limited")
  try error.info?.decode(Limit.self) // any JSON the server attached
  if error.code == 403 { }   // codes compare with literals
  if error.code == .timeout { }
}
```

Library codes: `.notFound` (no handler for the path), `.cancelled`, `.rateLimited` (`info: { retryAfter }`), and on the
client only `.timeout`, `.disconnected` (dropped with `replay: false`, or `stop()`) and `.decoding` (the response didn't
decode into the expected type; only that call fails).

## Subscriptions

```swift
let subscription = try await client.subscribe("chat/list", Room(id: 42)) { body in
  let event = try? body.decode(ChatEvent.self) // or: let event: ChatEvent = try body.body()
}
subscription.topic        // the topic the server returned, nil for a one-shot
subscription.isSubscribed // false for a one-shot, after cancel(), or once a resubscribe was refused
subscription.cancel()     // or release it
```

- The response body is the first event (a snapshot). After a reconnect the client subscribes again and the new
  response delivers a fresh snapshot. Events published while disconnected are lost.
- `body.isSnapshot` tells a snapshot (`true`) from a published event (`false`).
- A response without a topic is one-shot: its body is delivered once and the subscription ends.
- Events are delivered whenever the message has a `body`, including `0`, `false`, `""` and `null`.
- Cancelled subscriptions are not sent again after a reconnect. A resubscribe the server refuses ends the subscription.
- With `SendOptions(replay: false)`, a dropped connection ends the subscription instead of subscribing again.

## Tests

```bash
swift test
```

The old tests need the TS reference fixture on port 2049 (`bun tests/server.ts` in `channel/`). The wire v2 tests start
`Tests/Fixture/server.ts`, a raw Bun fixture with the same routes, on port 2051. To run them against the TS reference,
set `CHANNEL_FIXTURE_PORT=2049`.
