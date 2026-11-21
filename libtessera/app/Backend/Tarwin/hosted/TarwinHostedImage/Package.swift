// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinHostedImage",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinHostedImage", targets: ["TarwinHostedImage"])],
  dependencies: [
    .package(path: "../../../../../../tarwin/tarwin-task"),
    .package(path: "../../../../../../tarwin/tarwin-syscall/hosted/trap-decode"),
  ],
  targets: [
    .target(name: "TarwinHostedImage", dependencies: [
      .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
      .product(name: "TarwinTrapDecode", package: "trap-decode"),
    ]),
    .testTarget(name: "TarwinHostedImageTests", dependencies: ["TarwinHostedImage"]),
  ])
