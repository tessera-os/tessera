// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinNet", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinNetWire", targets: ["TarwinNetWire"]),
    .library(name: "TarwinNet", targets: ["TarwinNet"]),
  ],
  dependencies: [
    .package(path: "../tarwin-ipc"), .package(path: "../tarwin-device"),
    .package(path: "../tarwin-object"), .package(path: "../tarwin-syscall"),
  ],
  targets: [
    .target(
      name: "TarwinNetWire", dependencies: [.product(name: "TarwinIPC", package: "tarwin-ipc")]),
    .target(
      name: "TarwinNet",
      dependencies: [
        "TarwinNetWire", .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinIoCompletion", package: "tarwin-device"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "TarwinNetTests",
      dependencies: [
        "TarwinNet", "TarwinNetWire", .product(name: "TarwinDevice", package: "tarwin-device"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ], path: "tests/TarwinNetTests"),
  ]
)
