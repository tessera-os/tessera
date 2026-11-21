// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "HostedIOAcceptance", platforms: [.macOS(.v26)],
  products: [.executable(name: "hosted-io-e2e", targets: ["HostedIORunner"])],
  dependencies: [
    .package(path: "../../../tessera/build/tarwin-hosted"), .package(path: "../../tarwin-task"),
    .package(path: "../../trfs"), .package(path: "../../trfs/hosted/trfs-hosted"),
    .package(path: "../../tarwin-block/hosted/tarwin-block-hosted"),
    .package(path: "../../tarwin-net/hosted/tarwin-net-hosted"),
  ],
  targets: [
    .target(name: "HostedIOChecks", dependencies: [
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
      .product(name: "TRFS", package: "trfs"), .product(name: "TRFSHosted", package: "trfs-hosted"),
      .product(name: "TarwinBlockHosted", package: "tarwin-block-hosted"),
      .product(name: "TarwinNetHosted", package: "tarwin-net-hosted"),
    ]),
    .executableTarget(name: "HostedIORunner", dependencies: [
      "HostedIOChecks", .product(name: "TarwindKernel", package: "tarwin-hosted"),
      .product(name: "TarwinTaskTransport", package: "tarwin-task"),
    ]),
    .testTarget(name: "HostedIOChecksTests", dependencies: [
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
      "HostedIOChecks", .product(name: "TRFSHosted", package: "trfs-hosted"),
      .product(name: "TarwinNetHosted", package: "tarwin-net-hosted"),
    ]),
  ])
