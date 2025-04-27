// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let name = "ChannelSwift"
let package = Package(
  name: name,
  platforms: [.macOS(.v10_15)],
  products: [.library(name: name, targets: [name])],
  targets: [.target(name: name), .testTarget(name: "ChannelSwiftTests", dependencies: ["ChannelSwift"])]
)
