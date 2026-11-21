// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinMMHosted",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinMMHosted", targets: ["TarwinMMHosted"])],
  dependencies: [
    .package(path: "../.."), .package(path: "../../../tarwin-task"),
    .package(path: "../../../tarwin-arch-hosted"),
    .package(path: "../../../trfs/hosted/trfs-hosted"),
  ],
  targets: [
    .target(name: "TarwinMMHosted", dependencies: [
      .product(name: "TarwinMM", package: "tarwin-mm"),
      .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
      .product(name: "TarwinTaskTransport", package: "tarwin-task"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
    ]),
    .testTarget(name: "TarwinMMHostedTests", dependencies: [
      "TarwinMMHosted",
      .product(name: "tarwin-task", package: "tarwin-task"),
      .product(name: "TRFSHosted", package: "trfs-hosted"),
    ]),
  ]
)
