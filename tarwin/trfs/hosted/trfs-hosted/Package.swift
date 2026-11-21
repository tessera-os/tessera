// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TRFSHosted", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TRFSHosted", targets: ["TRFSHosted"]),
    .library(name: "TarwinHostFolder", targets: ["TarwinHostFolder"]),
  ],
  dependencies: [
    .package(path: "../.."), .package(path: "../../../tarwin-ipc"),
    .package(path: "../../../tarwin-block/hosted/tarwin-block-hosted"),
    .package(path: "../../../tarwin-device"),
  ],
  targets: [
    .target(
      name: "TRFSHosted",
      dependencies: [
        .product(name: "TRFS", package: "trfs"),
        .product(name: "TarwinBlockHosted", package: "tarwin-block-hosted"),
      ]),
    .target(
      name: "TarwinHostFolder",
      dependencies: [
        .product(name: "TarwinFsWire", package: "trfs"),
        .product(name: "TarwinReadOnlyFS", package: "trfs"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ]),
    .testTarget(
      name: "TRFSHostedTests",
      dependencies: [
        "TRFSHosted", "TarwinHostFolder", .product(name: "TRFS", package: "trfs"),
        .product(name: "TarwinFsWire", package: "trfs"),
        .product(name: "TarwinReadOnlyFS", package: "trfs"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinBlockHosted", package: "tarwin-block-hosted"),
        .product(name: "TarwinDevice", package: "tarwin-device"),
      ], path: "tests/TRFSHostedTests"),
  ]
)
