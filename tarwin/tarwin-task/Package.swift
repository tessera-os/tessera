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
  dependencies: [.package(name: "HostedGate", path: "../tarwin-syscall/hosted")],
  targets: [
    .target(name: "TarwinTaskProtocol"),
    .target(name: "TarwinTaskTransport", dependencies: ["TarwinTaskProtocol"]),
    .target(name: "CTarwinTaskGate"),
    .executableTarget(name: "TarwinTaskHost", dependencies: [
      "TarwinTaskProtocol", "TarwinTaskTransport", "CTarwinTaskGate",
      .product(name: "TarwinGateTransport", package: "HostedGate"),
    ]),
    .executableTarget(
      name: "TaskCheckInExample", dependencies: ["TarwinTaskTransport"],
      path: "Tests/TaskCheckInExample"),
    .testTarget(name: "TarwinTaskProtocolTests", dependencies: ["TarwinTaskProtocol"]),
    .testTarget(
      name: "TarwinTaskTransportTests",
      dependencies: ["TarwinTaskTransport", "TarwinTaskHost", "TaskCheckInExample"]),
  ])
