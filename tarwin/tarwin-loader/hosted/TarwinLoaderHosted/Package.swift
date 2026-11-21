// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinLoaderHosted",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinLoaderHosted", targets: ["TarwinLoaderHosted"])],
  dependencies: [
    .package(path: "../.."),
    .package(name: "TarwinMMHosted", path: "../../../tarwin-mm/hosted/TarwinMMHosted"),
  ],
  targets: [
    .target(name: "TarwinLoaderHosted", dependencies: [
      .product(name: "TarwinLoader", package: "tarwin-loader"),
      .product(name: "TarwinMMHosted", package: "TarwinMMHosted"),
    ]),
    .testTarget(name: "TarwinLoaderHostedTests", dependencies: ["TarwinLoaderHosted"]),
  ]
)
