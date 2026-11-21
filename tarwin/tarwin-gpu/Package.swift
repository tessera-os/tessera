// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinGPU",
  products: [.library(name: "TarwinGPU", targets: ["TarwinGPU"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinGPU", dependencies: []),
    .testTarget(name: "TarwinGPUTests", dependencies: ["TarwinGPU"]),
  ]
)
