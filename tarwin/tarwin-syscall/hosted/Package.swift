// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinHostedGate",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinHostedGate", targets: ["TarwinHostedGate"]),
    .library(name: "TarwinGateTransport", targets: ["TarwinGateTransport"]),
  ],
  dependencies: [.package(name: "TarwinSyscall", path: "..")],
  targets: [
    .target(name: "TarwinHostedGate", dependencies: [
      .product(name: "TarwinABI", package: "TarwinSyscall"),
    ]),
    .testTarget(name: "TarwinHostedGateTests", dependencies: ["TarwinHostedGate"]),
    .target(name: "TarwinGateTransport", dependencies: ["TarwinHostedGate"]),
    .testTarget(name: "TarwinGateTransportTests", dependencies: ["TarwinGateTransport"]),
  ])
