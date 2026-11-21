// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinHostedGate",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinHostedGate", targets: ["TarwinHostedGate"]),
    .library(name: "TarwinGateTransport", targets: ["TarwinGateTransport"]),
    .library(name: "TarwinKernelGate", targets: ["TarwinKernelGate"]),
  ],
  dependencies: [
    .package(name: "TarwinSyscall", path: ".."),
    .package(path: "../../../tessera/build/tarwin-hosted"),
  ],
  targets: [
    .target(name: "TarwinHostedGate", dependencies: [
      .product(name: "TarwinABI", package: "TarwinSyscall"),
    ]),
    .testTarget(name: "TarwinHostedGateTests", dependencies: ["TarwinHostedGate"]),
    .target(name: "TarwinGateTransport", dependencies: [
      "TarwinHostedGate", .product(name: "TarwinABI", package: "TarwinSyscall"),
    ]),
    .testTarget(name: "TarwinGateTransportTests", dependencies: ["TarwinGateTransport"]),
    .target(name: "TarwinKernelGate", dependencies: [
      "TarwinGateTransport", "TarwinHostedGate", .product(name: "TarwindKernel", package: "tarwin-hosted"),
    ]),
    .testTarget(name: "TarwinKernelGateTests", dependencies: [
      "TarwinKernelGate", "TarwinGateTransport", "TarwinHostedGate",
      .product(name: "TarwinABI", package: "TarwinSyscall"),
      .product(name: "TarwinSyscall", package: "TarwinSyscall"),
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
    ]),
  ])
