// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TRFS",
  products: [.library(name: "TRFS", targets: ["TRFS"])],
  dependencies: [],
  targets: [
    .target(name: "TRFS", dependencies: []),
    .testTarget(name: "TRFSTests", dependencies: ["TRFS"], path: "tests/TRFSTests"),
  ]
)
