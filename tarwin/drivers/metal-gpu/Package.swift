// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "HostedMetalGPU",
  platforms: [.macOS(.v26)],
  products: [.library(name: "HostedMetalGPU", targets: ["HostedMetalGPU"])],
  dependencies: [
    .package(path: "../tvgpu"),
    .package(path: "../../tarwin-arch-hosted"),
    .package(path: "../../tarwin-gpu"),
    .package(path: "../../tarwin-object"),
    .package(path: "../../tarwin-syscall"),
  ],
  targets: [
    .target(
      name: "HostedMetalGPU",
      dependencies: [
        .product(name: "MosaicMetal", package: "tvgpu"),
        .product(name: "TvGpuGuest", package: "tvgpu"),
        .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
        .product(name: "TarwinGPU", package: "tarwin-gpu"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "HostedMetalGPUTests",
      dependencies: [
        "HostedMetalGPU", .product(name: "TvGpuGuest", package: "tvgpu"),
        .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
        .product(name: "TarwinGPU", package: "tarwin-gpu"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
  ]
)
