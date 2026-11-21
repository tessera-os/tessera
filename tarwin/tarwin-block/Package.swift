// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinBlock", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinBlockWire", targets: ["TarwinBlockWire"]),
    .library(name: "TarwinBlock", targets: ["TarwinBlock"]),
  ],
  dependencies: [.package(path: "../tarwin-ipc")],
  targets: [
    .target(
      name: "TarwinBlockWire", dependencies: [.product(name: "TarwinIPC", package: "tarwin-ipc")]),
    .target(
      name: "TarwinBlock",
      dependencies: ["TarwinBlockWire", .product(name: "TarwinIPC", package: "tarwin-ipc")]),
    .testTarget(
      name: "TarwinBlockTests",
      dependencies: [
        "TarwinBlock", "TarwinBlockWire", .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ], path: "tests/TarwinBlockTests"),
  ]
)
