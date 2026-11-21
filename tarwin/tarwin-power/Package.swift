// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinPower",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinPower", targets: ["TarwinPower"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinPower", dependencies: []),
    .testTarget(
      name: "TarwinPowerTests", dependencies: ["TarwinPower"], path: "tests/TarwinPowerTests"),
  ]
)
