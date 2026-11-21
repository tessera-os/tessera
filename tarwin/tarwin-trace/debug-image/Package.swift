// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinDebugImage",
  products: [.library(name: "TarwinDebugImage", targets: ["TarwinDebugImage"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinDebugImage", dependencies: []),
    .testTarget(
      name: "TarwinDebugImageTests", dependencies: ["TarwinDebugImage"],
      path: "tests/TarwinDebugImageTests"),
  ]
)
