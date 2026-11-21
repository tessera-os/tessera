// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AdrenoGPU", platforms: [.macOS(.v26)],
  products: [.library(name: "AdrenoGPU", targets: ["AdrenoGPU"])],
  dependencies: [.package(path: "../../tarwin-device")],
  targets: [
    .target(
      name: "AdrenoGPU", dependencies: [.product(name: "TarwinDevice", package: "tarwin-device")]),
    .testTarget(
      name: "AdrenoGPUTests",
      dependencies: ["AdrenoGPU", .product(name: "TarwinDevice", package: "tarwin-device")],
      path: "tests/AdrenoGPUTests"),
  ])
