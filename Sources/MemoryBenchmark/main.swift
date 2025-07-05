//
//  File.swift
//  Channel
//
//  Created by Dmitry Kozlov on 5/7/25.
//

import Channel

let channel = Channel<Void>()
let client = channel.connect(2049)

var sent = 0
while true {
  for try await _: Int in client.values("stream/values") {
    
  }
  sent += 1
  if sent / 1000 != (sent - 1) / 1000 {
    print("Sent", sent, client.ws.pendingCount)
  }
}
