// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinLoader",
  products: [
    .library(name: "TarwinLoader", targets: ["TarwinLoader"]),
    .executable(name: "inspect-unsigned", targets: ["InspectUnsigned"]),
  ],
  targets: [
    .target(name: "TarwinLoader"),
    .executableTarget(
      name: "InspectUnsigned", dependencies: ["TarwinLoader"], path: "tests/InspectUnsigned"),
    .testTarget(
      name: "TarwinLoaderTests", dependencies: ["TarwinLoader"], path: "tests/TarwinLoaderTests"),
  ])
