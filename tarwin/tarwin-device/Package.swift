// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinDevice",
  products: [.library(name: "TarwinDevice", targets: ["TarwinDevice"])],
  targets: [
    .target(name: "TarwinDevice", dependencies: []),
    .testTarget(name: "TarwinDeviceTests", dependencies: ["TarwinDevice"]),
  ]
)
