import XCTest
@testable import ChannelSwift

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

let client = channel.connect(address: "2049", state: ())

class ClientTests: XCTestCase {
  func testPostHello() async throws {
    let response: String = try await client.send("hello")
    XCTAssertEqual(response, "world")
  }

  func testPostEcho() async throws {
    let random = Double.random(in: 0..<1)
    let response: Double = try await client.send("echo", body: random)
    XCTAssertEqual(response, random)
  }

  func testPostNoReturn() async throws {
    let response: Int? = try await client.send("empty")
    XCTAssertNil(response)
  }

  func testStream() async throws {
    var a = 0
    for try await value in client.values("stream/values", as: Int.self) {
      XCTAssertEqual(value, a)
      a += 1
    }
    XCTAssertEqual(a, 3)
  }

  func testStreamCancel() async throws {
    var a = 0
    for try await value in client.values("stream/cancel", as: Int.self) {
      print("[stream] received", value)
      XCTAssertEqual(value, a)
      a += 1
      if a == 2 {
        print("[stream] break")
        break
      }
    }
    XCTAssertEqual(a, 2)
  }

  func testServerPost() async throws {
    let response: String = try await client.send("mirror")
    XCTAssertEqual(response, "client world")
  }

  func testServerStream() async throws {
    var a = 0
    for try await value in client.values("mirror/stream", as: Int.self) {
      XCTAssertEqual(value, a)
      a += 1
    }
  }

  func testServerStreamCancel() async throws {
    var a = 0
    await MainActor.run {
      valuesSent = 0
    }
    for try await value in client.values("mirror/stream/cancel", as: Int.self) {
      XCTAssertEqual(value, a)
      a += 1
      if a == 2 { break }
    }
    // Allow some time for the server to process the cancellation
    await sleep(seconds: 0.1)
    await MainActor.run {
      XCTAssertEqual(valuesSent, 2)
    }
  }

  func testStateAuth() async throws {
    let newClient = Channel<Void>().connect(address: "2049")
    try await newClient.send("auth", body: ["name": "tester"])
    let name: String = try await newClient.send("auth/name")
    XCTAssertEqual(name, "tester")
    newClient.stop()
  }

  func testStateUnauthorized() async throws {
    let newClient = Channel<Void>().connect(address: "2049")

    // Test that unauthorized request throws an error
    do {
      try await newClient.send("auth/name")
      XCTFail("Expected to throw an error")
    } catch {
      XCTAssertTrue("\(error)".contains("unauthorized"))
    }
    newClient.stop()
  }
}
