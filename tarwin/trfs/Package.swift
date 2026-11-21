// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TRFS", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinFsWire", targets: ["TarwinFsWire"]),
    .library(name: "TarwinFAT", targets: ["TarwinFAT"]),
    .library(name: "TarwinArchive", targets: ["TarwinArchive"]),
    .library(name: "TarwinReadOnlyFS", targets: ["TarwinReadOnlyFS"]),
    .library(name: "TRFS", targets: ["TRFS"]),
  ],
  dependencies: [
    .package(path: "../tarwin-ipc"), .package(path: "../tarwin-mm"),
    .package(path: "../tarwin-device"), .package(path: "../tarwin-object"),
    .package(path: "../tarwin-syscall"),
  ],
  targets: [
    .target(
      name: "TarwinReadOnlyFS",
      dependencies: ["TarwinFsWire", .product(name: "TarwinIPC", package: "tarwin-ipc")]),
    .target(name: "TarwinFAT", dependencies: ["TarwinReadOnlyFS"]),
    .target(name: "TarwinArchive", dependencies: ["TarwinReadOnlyFS"]),
    .testTarget(
      name: "FATTests",
      dependencies: [
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinIoCompletion", package: "tarwin-device"),
        "TarwinFAT", "TarwinArchive", "TarwinReadOnlyFS", "TRFS", "TarwinFsWire",
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinDevice", package: "tarwin-device"),
      ], path: "tests/FATTests"),
    .target(
      name: "TarwinFsWire", dependencies: [.product(name: "TarwinIPC", package: "tarwin-ipc")]),
    .target(
      name: "TRFS",
      dependencies: [
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinIoCompletion", package: "tarwin-device"),
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
