// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinObject", products: [.library(name: "TarwinObject", targets: ["TarwinObject"])],
  targets: [
    .target(name: "TarwinObject"),
    .testTarget(
      name: "TarwinObjectTests", dependencies: ["TarwinObject"], path: "tests/TarwinObjectTests"),
  ])
