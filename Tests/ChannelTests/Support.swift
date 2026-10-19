import Foundation
import Testing
@testable import Channel

/// Port of the wire v2 fixture: `CHANNEL_FIXTURE_PORT`, default 2051 (the raw Bun fixture in `Tests/Fixture`).
/// Set it to 2049 to run the same tests against the TS reference fixture (`channel/tests/server.ts`).
enum Fixture {
  static let port = Int(ProcessInfo.processInfo.environment["CHANNEL_FIXTURE_PORT"] ?? "") ?? 2051
  @MainActor private static var started: Task<Void, Never>?

  /// Starts `Tests/Fixture/server.ts` once per test run, unless the port is 2049 or something already listens on it.
  /// The fixture exits when the test process does.
  @MainActor static func start() async {
    if let started { return await started.value }
    let task = Task { @MainActor in
      #if os(macOS)
      guard port != 2049 else { return }
      let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixture/server.ts")
      let process = Process()
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      let bun = ["\(home)/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
      if let bun {
        process.executableURL = URL(fileURLWithPath: bun)
        process.arguments = [script.path]
      } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bun", script.path]
      }
      var environment = ProcessInfo.processInfo.environment
      environment["CHANNEL_FIXTURE_PORT"] = "\(port)"
      environment["FIXTURE_PARENT_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
      process.environment = environment
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      do {
        try process.run()
      } catch {
        print("fixture: can't start bun:", error)
        return
      }
      // Wait for "listening" or for the process to exit (port already in use: someone else serves it)
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let done = UnsafeMutable(false)
        let lock = NSLock()
        let finish: @Sendable () -> Void = {
          lock.lock()
          defer { lock.unlock() }
          guard !done.value else { return }
          done.value = true
          continuation.resume()
        }
        output.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          if data.isEmpty || String(decoding: data, as: UTF8.self).contains("listening") {
            handle.readabilityHandler = nil
            finish()
          }
        }
        process.terminationHandler = { _ in finish() }
      }
      #endif
    }
    started = task
    await task.value
  }

  @MainActor static func client(_ options: ClientOptions<Void> = ClientOptions()) async -> ClientSender<Void> {
    await start()
    let client = Channel<Void>().connect(port, options: options)
    await waitUntil { client.connectionState == .connected }
    return client
  }
}

/// Polls `condition` on the main actor until it holds or `timeout` seconds pass
@MainActor
@discardableResult
func waitUntil(_ timeout: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    if Date() > deadline { return false }
    await sleep(seconds: 0.005)
  }
  return true
}

/// A few JSON values, for recording events
enum JSONValue: Decodable, Equatable, Sendable {
  case null, bool(Bool), int(Int), string(String)
  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else {
      self = try .string(container.decode(String.self))
    }
  }
}

@MainActor
final class Events {
  var values = [JSONValue]()
  var handler: @Sendable @MainActor (AnyBody) -> Void {
    { [weak self] body in
      self?.values.append((try? body.decode(JSONValue.self)) ?? .string("<undecodable>"))
    }
  }
}

/// Expects `body` to throw a `ChannelError` and returns it
@MainActor
func channelError(_ body: @MainActor () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async -> ChannelError? {
  do {
    try await body()
    Issue.record("expected an error", sourceLocation: sourceLocation)
    return nil
  } catch let error as ChannelError {
    return error
  } catch {
    Issue.record("expected a ChannelError, got \(error)", sourceLocation: sourceLocation)
    return nil
  }
}

extension WebSocketClient {
  /// Drops the current connection as if the network failed
  func dropConnection() {
    connectionLost(currentTask)
  }
}
