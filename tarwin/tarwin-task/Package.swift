// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinTaskProtocol",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinTaskProtocol", targets: ["TarwinTaskProtocol"]),
    .library(name: "TarwinTaskTransport", targets: ["TarwinTaskTransport"]),
  ],
  targets: [
    .target(name: "TarwinTaskProtocol"),
    .target(name: "TarwinTaskTransport", dependencies: ["TarwinTaskProtocol"]),
    .testTarget(name: "TarwinTaskProtocolTests", dependencies: ["TarwinTaskProtocol"]),
    .testTarget(name: "TarwinTaskTransportTests", dependencies: ["TarwinTaskTransport"]),
  ])
