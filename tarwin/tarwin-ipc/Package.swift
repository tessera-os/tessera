// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinIPC", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinIPC", targets: ["TarwinIPC"]),
    .library(name: "TarwinIPCChannels", targets: ["TarwinIPCChannels"]),
    .library(name: "TarwinIPCObservers", targets: ["TarwinIPCObservers"]),
  ],
  dependencies: [
    .package(path: "../tarwin-object"), .package(path: "../tarwin-syscall"),
    .package(path: "../tarwin-sched"),
  ],
  targets: [
    .target(name: "TarwinIPC"),
    .target(
      name: "TarwinIPCObservers",
      dependencies: [
        "TarwinIPC", .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
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
        "TarwinIPC", "TarwinIPCChannels", "TarwinIPCObservers",
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSched", package: "tarwin-sched"),
      ], path: "tests/TarwinIPCTests"),
  ])
