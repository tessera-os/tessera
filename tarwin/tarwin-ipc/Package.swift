// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinIPC", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinIPC", targets: ["TarwinIPC"]),
    .library(name: "TarwinIPCChannels", targets: ["TarwinIPCChannels"]),
  ],
  dependencies: [.package(path: "../tarwin-object")],
  targets: [
    .target(name: "TarwinIPC"),
    .target(
      name: "TarwinIPCChannels",
      dependencies: ["TarwinIPC", .product(name: "TarwinObject", package: "tarwin-object")]),
    .testTarget(
      name: "TarwinIPCTests",
      dependencies: [
        "TarwinIPC", "TarwinIPCChannels", .product(name: "TarwinObject", package: "tarwin-object"),
      ], path: "tests/TarwinIPCTests"),
  ])
