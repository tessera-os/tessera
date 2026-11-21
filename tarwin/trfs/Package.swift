// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TRFS", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinFsWire", targets: ["TarwinFsWire"]),
    .library(name: "TarwinFAT", targets: ["TarwinFAT"]),
    .library(name: "TRFS", targets: ["TRFS"]),
  ],
  dependencies: [
    .package(path: "../tarwin-ipc"), .package(path: "../tarwin-mm"),
    .package(path: "../tarwin-device"),
  ],
  targets: [
    .target(
      name: "TarwinFAT",
      dependencies: ["TarwinFsWire", .product(name: "TarwinIPC", package: "tarwin-ipc")]),
    .testTarget(
      name: "FATTests",
      dependencies: [
        "TarwinFAT", "TRFS", "TarwinFsWire", .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinDevice", package: "tarwin-device"),
      ], path: "tests/FATTests"),
    .target(
      name: "TarwinFsWire", dependencies: [.product(name: "TarwinIPC", package: "tarwin-ipc")]),
    .target(
      name: "TRFS",
      dependencies: [
        "TarwinFsWire", .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinMM", package: "tarwin-mm"),
      ]),
    .testTarget(
      name: "TRFSTests",
      dependencies: [
        "TRFS", "TarwinFsWire", .product(name: "TarwinDevice", package: "tarwin-device"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ], path: "tests/TRFSTests"),
  ]
)
