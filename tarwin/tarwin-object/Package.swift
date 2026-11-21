// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinObject", platforms: [.macOS(.v15)],
  products: [
    .library(name: "TarwinObject", targets: ["TarwinObject"]),
  ],
  targets: [
    .target(name: "TarwinObject"),
    .testTarget(
      name: "TarwinObjectTests",
      dependencies: ["TarwinObject"], path: "tests/TarwinObjectTests"),
  ])
