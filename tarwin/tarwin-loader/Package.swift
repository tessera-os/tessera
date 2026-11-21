// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinLoader", products: [.library(name: "TarwinLoader", targets: ["TarwinLoader"])],
  targets: [
    .target(name: "TarwinLoader"),
    .testTarget(
      name: "TarwinLoaderTests", dependencies: ["TarwinLoader"], path: "tests/TarwinLoaderTests"),
  ])
