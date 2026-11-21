// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinTaskProtocol",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinTaskProtocol", targets: ["TarwinTaskProtocol"])],
  targets: [
    .target(name: "TarwinTaskProtocol"),
    .testTarget(name: "TarwinTaskProtocolTests", dependencies: ["TarwinTaskProtocol"]),
  ])
