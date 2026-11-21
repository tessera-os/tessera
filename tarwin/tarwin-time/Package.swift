// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinTime",
  platforms: [.macOS(.v13)],
  products: [.library(name: "TarwinTime", targets: ["TarwinTime"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinTime", dependencies: []),
    .testTarget(
      name: "TarwinTimeTests", dependencies: ["TarwinTime"], path: "tests/TarwinTimeTests"),
  ]
)
