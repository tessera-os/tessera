// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinTaskProtocol",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinTaskProtocol", targets: ["TarwinTaskProtocol"]),
    .library(name: "TarwinTaskTransport", targets: ["TarwinTaskTransport"]),
    .executable(name: "tarwin-task", targets: ["TarwinTaskHost"]),
  ],
  targets: [
    .target(name: "TarwinTaskProtocol"),
    .target(name: "TarwinTaskTransport", dependencies: ["TarwinTaskProtocol"]),
    .executableTarget(
      name: "TarwinTaskHost", dependencies: ["TarwinTaskProtocol", "TarwinTaskTransport"]),
    .testTarget(name: "TarwinTaskProtocolTests", dependencies: ["TarwinTaskProtocol"]),
    .testTarget(name: "TarwinTaskTransportTests", dependencies: ["TarwinTaskTransport", "TarwinTaskHost"]),
  ])
