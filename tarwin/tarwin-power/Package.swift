// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinPower",
  products: [.library(name: "TarwinPower", targets: ["TarwinPower"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinPower", dependencies: []),
    .testTarget(name: "TarwinPowerTests", dependencies: ["TarwinPower"]),
  ]
)
