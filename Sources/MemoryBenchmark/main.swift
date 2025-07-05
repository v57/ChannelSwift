//
//  File.swift
//  Channel
//
//  Created by Dmitry Kozlov on 5/7/25.
//

import Channel

let channel = Channel<Void>()
let client = channel.connect(2049)

@MainActor
func runSync() async throws {
  for try await _: Int in client.values("stream/sync") { }
}
@MainActor
func runSyncWithBreak() async throws {
  for try await value: Int in client.values("stream/sync") {
    if value == 2 { break }
  }
}

var sent = 0
while true {
  try await runSync()
  sent += 1
  if sent / 1000 != (sent - 1) / 1000 {
    print("Sent", sent, client.ws.pendingCount)
  }
}
sent = 0
while true {
  try await runSyncWithBreak()
  sent += 1
  if sent / 1000 != (sent - 1) / 1000 {
    print("Sent", sent, client.ws.pendingCount)
  }
}
