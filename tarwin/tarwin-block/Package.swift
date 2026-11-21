// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinBlock",
  products: [.library(name: "TarwinBlock", targets: ["TarwinBlock"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinBlock", dependencies: []),
    .testTarget(
      name: "TarwinBlockTests", dependencies: ["TarwinBlock"], path: "tests/TarwinBlockTests"),
  ]
)
