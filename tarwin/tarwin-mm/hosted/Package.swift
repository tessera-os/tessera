// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinMMHosted",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinMMHosted", targets: ["TarwinMMHosted"])],
  dependencies: [
    .package(path: ".."), .package(path: "../../tarwin-task"),
    .package(path: "../../tarwin-arch-hosted"),
  ],
  targets: [
    .target(name: "TarwinMMHosted", dependencies: [
      .product(name: "TarwinMM", package: "tarwin-mm"),
      .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
    ]),
    .testTarget(name: "TarwinMMHostedTests", dependencies: ["TarwinMMHosted"]),
  ]
)
