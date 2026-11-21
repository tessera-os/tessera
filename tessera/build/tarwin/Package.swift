// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinBootstrap", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinBootstrap", targets: ["TarwinBootstrap"])],
  dependencies: [
    .package(path: "../../../tarwin/tarwin-sched"),
    .package(path: "../../../tarwin/tarwin-time"),
  ],
  targets: [
    .target(
      name: "TarwinBootstrap",
      dependencies: [
        .product(name: "TarwinSched", package: "tarwin-sched"),
        .product(name: "TarwinTime", package: "tarwin-time"),
      ]),
    .testTarget(name: "TarwinBootstrapTests", dependencies: ["TarwinBootstrap"]),
  ])
