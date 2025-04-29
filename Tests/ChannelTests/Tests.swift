import Testing
@testable import Channel

func sleep(seconds: Double = 0.001) async {
  try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
@MainActor
var valuesSent = 0
let channel = Channel<Void>()
  .post("hello") { "client world" }
  .stream("stream/values") { c in
    for i in 0..<3 {
      c.yield(i)
      await sleep()
    }
    c.finish()
  }
  .stream("stream/cancel") { c in
    for i in 0..<10 {
      c.yield(i)
      await MainActor.run {
        valuesSent += 1
      }
      await sleep(seconds: 0.2)
    }
    c.finish()
  }

let client = channel.connect(2049)

@Test("hello")
func hello() async throws {
  let response: String = try await client.send("hello")
  #expect(response == "world")
}

@Test("echo")
func echo() async throws {
  let random = Double.random(in: 0..<1)
  let response: Double = try await client.send("echo", random)
  #expect(response == random)
}

@Test("empty")
func noReturn() async throws {
  let response: Int? = try await client.send("empty")
  #expect(response == nil)
}

@Test("stream/values")
@MainActor
func stream() async throws {
  var a = 0
  for try await value in client.values("stream/values", as: Int.self) {
    #expect(value == a)
    a += 1
  }
  #expect(a == 3)
}

@Test("stream/cancel")
@MainActor
func streamCancel() async throws {
  var a = 0
  for try await value in client.values("stream/cancel", as: Int.self) {
    #expect(value == a)
    a += 1
    if a == 2 {
      break
    }
  }
  #expect(a == 2)
}

@Test("mirror")
func serverPost() async throws {
  let response: String = try await client.send("mirror")
  #expect(response == "client world")
}

@Test("mirror/stream")
@MainActor
func serverStream() async throws {
  var a = 0
  for try await value in client.values("mirror/stream", as: Int.self) {
    #expect(value == a)
    a += 1
  }
}

@Test("mirror/stream/cancel")
@MainActor
func serverStreamCancel() async throws {
  var a = 0
  await MainActor.run {
    valuesSent = 0
  }
  for try await value in client.values("mirror/stream/cancel", as: Int.self) {
    #expect(value == a)
    a += 1
    if a == 2 { break }
  }
  // Allow some time for the server to process the cancellation
  await sleep(seconds: 0.1)
  await MainActor.run {
    #expect(valuesSent == 2)
  }
}

@Test("auth/name")
@MainActor
func stateAuth() async throws {
  let newClient = Channel<Void>().connect(2049)
  try await newClient.send("auth", ["name": "tester"])
  let name: String = try await newClient.send("auth/name")
  #expect(name == "tester")
  newClient.stop()
}

@Test("auth/name/failed")
@MainActor
func unauthorized() async throws {
  let newClient = Channel<Void>().connect(2049)

  // Test that unauthorized request throws an error
  do {
    try await newClient.send("auth/name")
    #expect(Bool(false), "Expected to throw an error")
  } catch {
    #expect("\(error)".contains("unauthorized"))
  }
  newClient.stop()
}

