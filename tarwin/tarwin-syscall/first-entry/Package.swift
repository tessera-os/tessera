// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinArmBootstrap", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinArmBootstrap", targets: ["TarwinArmBootstrap"])],
  dependencies: [
    .package(path: "../../tarwin-arch-aarch64"), .package(path: "../../tarwin-object"),
    .package(path: "../../tarwin-ipc"),
  ],
  targets: [.target(name: "TarwinArmBootstrap", dependencies: [
    .product(name: "TarwinArchAarch64", package: "tarwin-arch-aarch64"),
    .product(name: "TarwinObject", package: "tarwin-object"),
    .product(name: "TarwinIPCChannels", package: "tarwin-ipc"),
  ])])
