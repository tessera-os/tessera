// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinBootstrap", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinBootstrap", targets: ["TarwinBootstrap"]),
    .library(name: "TarbootPreflight", targets: ["TarbootPreflight"]),
  ],
  dependencies: [
    .package(path: "../../../tarwin/tarwin-sched"),
    .package(path: "../../../tarwin/tarwin-time"),
    .package(path: "../../../tarwin/kcore"),
    .package(path: "../../../tarwin/tarboot"),
    .package(path: "../../../tarwin/tarwin-loader"),
  ],
  targets: [
    .target(
      name: "TarwinBootstrap",
      dependencies: [
        .product(name: "TarwinSched", package: "tarwin-sched"),
        .product(name: "TarwinTime", package: "tarwin-time"),
      ]),
    .testTarget(name: "TarwinBootstrapTests", dependencies: ["TarwinBootstrap"]),
    .target(
      name: "TarbootPreflight",
      dependencies: [
        .product(name: "KCore", package: "kcore"),
        .product(name: "Tarboot", package: "tarboot"),
        .product(name: "TarwinLoader", package: "tarwin-loader"),
      ]),
    .testTarget(name: "TarbootPreflightTests", dependencies: ["TarbootPreflight"]),
  ])
