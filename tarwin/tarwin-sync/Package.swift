// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinSync", platforms: [.macOS(.v15)], products: [.library(name: "TarwinSync", targets: ["TarwinSync"])],
  targets: [
    .target(name: "TarwinSync"),
    .testTarget(
      name: "TarwinSyncTests", dependencies: ["TarwinSync"], path: "tests/TarwinSyncTests"),
  ])
