// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TRFS", platforms: [.macOS(.v13)],
  products: [.library(name: "TRFS", targets: ["TRFS"])],
  dependencies: [.package(path: "../tarwin-mm")],
  targets: [
    .target(name: "TRFS", dependencies: [.product(name: "TarwinMM", package: "tarwin-mm")]),
    .testTarget(name: "TRFSTests", dependencies: ["TRFS"], path: "tests/TRFSTests"),
  ]
)
