// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinNetHosted", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinNetHosted", targets: ["TarwinNetHosted"])],
  targets: [
    .target(name: "TarwinNetHosted"),
    .testTarget(
      name: "TarwinNetHostedTests", dependencies: ["TarwinNetHosted"],
      path: "tests/TarwinNetHostedTests"),
  ]
)
