// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let name = "Channel"
let package = Package(
  name: name,
  platforms: [.macOS(.v10_15), .iOS(.v13), .visionOS(.v1), .tvOS(.v13), .watchOS(.v6), .macCatalyst(.v13)],
  products: [.library(name: name, targets: [name])],
  targets: [
    .target(name: name),
    .executableTarget(name: "Benchmark", dependencies: ["Channel"]),
    .executableTarget(name: "MemoryBenchmark", dependencies: ["Channel"]),
    .testTarget(name: "ChannelTests", dependencies: ["Channel"])
  ]
)
