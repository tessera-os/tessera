// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TVMM",
  products: [
    .library(name: "TVMM", targets: ["TVMM"]),
    .library(name: "AndroidAgent", targets: ["AndroidAgent"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "AndroidWire"),
    .target(name: "AndroidAgent", dependencies: ["AndroidWire"]),
    .target(name: "TVMM", dependencies: ["AndroidWire"]),
    .testTarget(
      name: "TVMMTests", dependencies: ["TVMM", "AndroidAgent", "AndroidWire"],
      path: "tests/TVMMTests"),
  ]
)
