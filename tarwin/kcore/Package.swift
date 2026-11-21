// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "KCore",
  platforms: [.macOS(.v13)],
  products: [.library(name: "KCore", targets: ["KCore"])],
  dependencies: [],
  targets: [
    .target(name: "KCore", dependencies: []),
    .testTarget(name: "KCoreTests", dependencies: ["KCore"], path: "tests/KCoreTests"),
  ]
)
