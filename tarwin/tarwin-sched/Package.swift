// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinSched", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinSched", targets: ["TarwinSched"])],
  targets: [
    .target(name: "TarwinSched"),
    .testTarget(
      name: "TarwinSchedTests", dependencies: ["TarwinSched"], path: "tests/TarwinSchedTests"),
  ])
