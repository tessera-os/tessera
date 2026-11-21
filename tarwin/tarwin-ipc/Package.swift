// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinIPC", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinIPC", targets: ["TarwinIPC"]),
    .library(name: "TarwinIPCChannels", targets: ["TarwinIPCChannels"]),
  ],
  dependencies: [
    .package(path: "../tarwin-object"), .package(path: "../tarwin-syscall"),
    .package(path: "../tarwin-sched"),
  ],
  targets: [
    .target(name: "TarwinIPC"),
    .target(
      name: "TarwinIPCChannels",
      dependencies: [
        "TarwinIPC", .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSched", package: "tarwin-sched"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "TarwinIPCTests",
      dependencies: [
        "TarwinIPC", "TarwinIPCChannels", .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSched", package: "tarwin-sched"),
      ], path: "tests/TarwinIPCTests"),
  ])
