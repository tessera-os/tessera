// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinHostedGate",
  products: [.library(name: "TarwinHostedGate", targets: ["TarwinHostedGate"])],
  dependencies: [.package(name: "TarwinSyscall", path: "..")],
  targets: [
    .target(name: "TarwinHostedGate", dependencies: [
      .product(name: "TarwinABI", package: "TarwinSyscall"),
    ]),
    .testTarget(name: "TarwinHostedGateTests", dependencies: ["TarwinHostedGate"]),
  ])
