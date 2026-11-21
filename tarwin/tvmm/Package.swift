// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TVMM",
  products: [.library(name: "TVMM", targets: ["TVMM"])],
  dependencies: [],
  targets: [
    .target(name: "TVMM", dependencies: []),
    .testTarget(name: "TVMMTests", dependencies: ["TVMM"], path: "tests/TVMMTests"),
  ]
)
