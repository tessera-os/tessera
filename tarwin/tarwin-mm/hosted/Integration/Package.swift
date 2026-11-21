// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "HostedPagerIntegration",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(name: "TarwinMMHosted", path: "../TarwinMMHosted"),
    .package(path: "../../../tarwin-task"),
    .package(path: "../../../tarwin-arch-hosted"),
    .package(path: "../../../trfs/hosted/trfs-hosted"),
    .package(path: "../../../../tessera/build/tarwin-hosted"),
  ],
  targets: [
    .testTarget(name: "HostedPagerIntegrationTests", dependencies: [
      .product(name: "TarwinMMHosted", package: "TarwinMMHosted"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
      .product(name: "tarwin-task", package: "tarwin-task"),
      .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
      .product(name: "TarwinTaskTransport", package: "tarwin-task"),
      .product(name: "TRFSHosted", package: "trfs-hosted"),
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
    ]),
  ]
)
