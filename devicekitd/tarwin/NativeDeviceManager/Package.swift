// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NativeDeviceManager",
  platforms: [.macOS(.v15)],
  products: [.library(name: "NativeDeviceManager", targets: ["NativeDeviceManager"])],
  dependencies: [.package(name: "NativeDriverKit", path: "../../../devicekit")],
  targets: [
    .target(
      name: "NativeDeviceManager",
      dependencies: [.product(name: "NativeDriverKit", package: "NativeDriverKit")]),
    .testTarget(name: "NativeDeviceManagerTests", dependencies: ["NativeDeviceManager"]),
  ]
)
