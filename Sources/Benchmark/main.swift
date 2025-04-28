//
//  main.swift
//  ChannelSwift
//
//  Created by Dmitry Kozlov on 28/4/25.
//

import ChannelSwift
import Dispatch

let channel = Channel<Void>()
let client = channel.connect(address: "2049", state: ())

func _send(_ count: Int) async throws {
  for _ in 0..<count {
    try await client.send("hello")
  }
}
func send(_ count: Int) async throws {
  let t = DispatchTime.now()
  try await _send(count)
  let d = Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000_000
  print(String(format: "%.2fs", d), "Threads: 1")
}
func send(_ threads: Int, _ count: Int) async throws {
  let t = DispatchTime.now()
  try await withThrowingTaskGroup { group in
    for _ in 0..<threads {
      group.addTask {
        try await _send(count)
      }
    }
    try await group.waitForAll()
  }
  let d = Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000_000
  print(String(format: "%.2fs", d), "Threads:", threads)
}

print("Sending 10000 requests")
try await send(10000)
try await send(10, 1000)
try await send(100, 100)
try await send(1000, 10)
try await send(10000, 1)

/*
 Results on M3 cpu
 0.97s Threads: 1
 0.38s Threads: 10
 0.42s Threads: 100
 0.32s Threads: 1000
 0.30s Threads: 10000
 */
