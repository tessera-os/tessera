// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinStage0", platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../../../../languages/klf-swift"),
    .package(path: "../../../tarwin/tarwin-loader"),
    .package(name: "TarwinBootstrap", path: "../tarwin"),
  ],
  targets: [
    .executableTarget(
      name: "Stage0Image",
      dependencies: [
        .product(name: "KLF", package: "klf-swift"),
        .product(name: "TarwinLoader", package: "tarwin-loader"),
      ]),
    .testTarget(
      name: "Stage0ImageTests",
      dependencies: [
        "Stage0Image",
        .product(name: "TarbootPreflight", package: "TarwinBootstrap"),
      ]),
  ])
