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
