// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NativeDriverKit",
  products: [.library(name: "NativeDriverKit", targets: ["NativeDriverKit"])],
  dependencies: [],
  targets: [
    .target(name: "NativeDriverKit", dependencies: []),
    .testTarget(name: "NativeDriverKitTests", dependencies: ["NativeDriverKit"]),
  ]
)
