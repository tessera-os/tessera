// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinMMHosted",
  platforms: [.macOS(.v13)],
  products: [.library(name: "TarwinMMHosted", targets: ["TarwinMMHosted"])],
  dependencies: [.package(path: "..")],
  targets: [
    .target(name: "TarwinMMHosted", dependencies: [.product(name: "TarwinMM", package: "tarwin-mm")]),
    .testTarget(name: "TarwinMMHostedTests", dependencies: ["TarwinMMHosted"]),
  ]
)
