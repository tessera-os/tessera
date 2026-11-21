// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinHostedImage",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinHostedImage", targets: ["TarwinHostedImage"])],
  dependencies: [
    .package(path: "../../../../../../tarwin/tarwin-task"),
    .package(path: "../../../../../../tarwin/tarwin-arch-hosted"),
    .package(path: "../../../../../../tarwin/tarwin-syscall"),
    .package(name: "HostedGate", path: "../../../../../../tarwin/tarwin-syscall/hosted"),
    .package(path: "../../../../../../tessera/build/tarwin-hosted"),
  ],
  targets: [
    .target(name: "TarwinHostedImage", dependencies: [
      .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
    ]),
    .testTarget(name: "TarwinHostedImageTests", dependencies: [
      "TarwinHostedImage",
      .product(name: "tarwin-task", package: "tarwin-task"),
      .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
      .product(name: "TarwinTaskTransport", package: "tarwin-task"),
      .product(name: "TarwinGateTransport", package: "HostedGate"),
      .product(name: "TarwinHostedGate", package: "HostedGate"),
      .product(name: "TarwinKernelGate", package: "HostedGate"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
      .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      .product(name: "TarwinABI", package: "tarwin-syscall"),
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
    ]),
  ])
