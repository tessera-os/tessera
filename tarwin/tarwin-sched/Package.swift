// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinSched", products: [.library(name: "TarwinSched", targets: ["TarwinSched"])],
  targets: [
    .target(name: "TarwinSched"),
    .testTarget(
      name: "TarwinSchedTests", dependencies: ["TarwinSched"], path: "tests/TarwinSchedTests"),
  ])
