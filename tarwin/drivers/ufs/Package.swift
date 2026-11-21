// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "UFSDriver", platforms: [.macOS(.v26)],
  products: [.library(name: "UFSDriver", targets: ["UFSDriver"])],
  dependencies: [.package(path: "../../tarwin-block"), .package(path: "../../tarwin-ipc")],
  targets: [
    .target(
      name: "UFSDriver",
      dependencies: [
        .product(name: "TarwinBlockWire", package: "tarwin-block"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ]),
    .testTarget(name: "UFSDriverTests", dependencies: ["UFSDriver"], path: "tests/UFSDriverTests"),
  ])
