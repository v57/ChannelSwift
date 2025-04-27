import XCTest
@testable import ChannelSwift

func sleep(seconds: Double = 0.001) async {
  try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
var valuesSent = 0
let channel = Channel<Void>()
  .post("hello", request: { _, _  in "client world" })
  .stream("stream/values") { _, _ in
    return AsyncThrowingStream { continuation in
      Task {
        for i in 0..<3 {
          continuation.yield(i)
          await sleep()
        }
        continuation.finish()
      }
    }
  }
  .stream("stream/cancel") { _, _ in
    return AsyncThrowingStream { continuation in
      Task {
        for i in 0..<10 {
          continuation.yield(i)
          valuesSent += 1
          await sleep(seconds: 0.2)
        }
        continuation.finish()
      }
    }
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
    valuesSent = 0
    for try await value in client.values("mirror/stream/cancel", as: Int.self) {
      XCTAssertEqual(value, a)
      a += 1
      if a == 2 { break }
    }
    // Allow some time for the server to process the cancellation
    await sleep(seconds: 0.1)
    XCTAssertEqual(valuesSent, 2)
  }

  func testStateAuth() async throws {
    let newClient = Channel<Void>().connect(address: "2049")
    try await newClient.send("auth", body: ["name": "tester"])
    let name: String = try await newClient.send("auth/name")
    XCTAssertEqual(name, "tester")
    newClient.stop()
  }

  func testStateUnauthorized() async throws {
    let newClient = Channel<Any>().connect(address: "2049", state: [:])

    // Test that unauthorized request throws an error
    do {
      try await newClient.send("auth/name")
      XCTFail("Expected to throw an error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("unauthorized"))
    }
    newClient.stop()
  }
}
