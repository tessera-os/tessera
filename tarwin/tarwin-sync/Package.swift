// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinSync", platforms: [.macOS(.v15)],
  products: [
    .library(name: "TarwinSync", targets: ["TarwinSync"]),
    .library(name: "TarwinSyncObjects", targets: ["TarwinSyncObjects"]),
  ],
  dependencies: [.package(path: "../tarwin-object")],
  targets: [
    .target(name: "TarwinSync"),
    .target(
      name: "TarwinSyncObjects",
      dependencies: ["TarwinSync", .product(name: "TarwinObject", package: "tarwin-object")]),
    .testTarget(
      name: "TarwinSyncTests",
      dependencies: [
        "TarwinSync", "TarwinSyncObjects", .product(name: "TarwinObject", package: "tarwin-object"),
      ], path: "tests/TarwinSyncTests"),
  ])
