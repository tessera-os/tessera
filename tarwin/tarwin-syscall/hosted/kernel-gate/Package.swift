// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinKernelGate",
  platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinKernelGate", targets: ["TarwinKernelGate"])],
  dependencies: [
    .package(name: "HostedGate", path: ".."),
    .package(path: "../.."),
    .package(path: "../../../tarwin-arch-hosted"),
    .package(path: "../../../tarwin-task"),
    .package(path: "../../../../libtessera/app/Backend/Tarwin/hosted/TarwinHostedImage"),
    .package(path: "../../../../tessera/build/tarwin-hosted"),
  ],
  targets: [
    .target(name: "TarwinKernelGate", dependencies: [
      .product(name: "TarwinGateTransport", package: "HostedGate"),
      .product(name: "TarwinHostedGate", package: "HostedGate"),
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
    ]),
    .testTarget(name: "TarwinKernelGateTests", dependencies: [
      "TarwinKernelGate",
      .product(name: "TarwinGateTransport", package: "HostedGate"),
      .product(name: "TarwinHostedGate", package: "HostedGate"),
      .product(name: "TarwinABI", package: "tarwin-syscall"),
      .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
    ]),
    .testTarget(name: "HostedTaskTests", dependencies: [
      "TarwinKernelGate",
      .product(name: "TarwinHostedImage", package: "TarwinHostedImage"),
      .product(name: "tarwin-task", package: "tarwin-task"),
      .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
      .product(name: "TarwinTaskTransport", package: "tarwin-task"),
      .product(name: "TarwinGateTransport", package: "HostedGate"),
      .product(name: "TarwinHostedGate", package: "HostedGate"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
      .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      .product(name: "TarwinABI", package: "tarwin-syscall"),
      .product(name: "TarwindKernel", package: "tarwin-hosted"),
    ]),
  ])
