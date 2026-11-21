// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinNet",
  products: [.library(name: "TarwinNet", targets: ["TarwinNet"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinNet", dependencies: []),
    .testTarget(name: "TarwinNetTests", dependencies: ["TarwinNet"]),
  ]
)
