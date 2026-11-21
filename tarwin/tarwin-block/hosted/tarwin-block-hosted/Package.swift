// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinBlockHosted", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinBlockHosted", targets: ["TarwinBlockHosted"])],
  dependencies: [.package(path: "../.."), .package(path: "../../../tarwin-ipc")],
  targets: [
    .target(
      name: "TarwinBlockHosted",
      dependencies: [
        .product(name: "TarwinBlockWire", package: "tarwin-block"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ]),
    .testTarget(
      name: "TarwinBlockHostedTests",
      dependencies: [
        "TarwinBlockHosted", .product(name: "TarwinBlockWire", package: "tarwin-block"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ], path: "tests/TarwinBlockHostedTests"),
  ]
)
