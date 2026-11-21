// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinGPU",
  platforms: [.macOS(.v15)],
  products: [.library(name: "TarwinGPU", targets: ["TarwinGPU"])],
  dependencies: [.package(path: "../tarwin-object"), .package(path: "../tarwin-syscall")],
  targets: [
    .target(
      name: "TarwinGPU",
      dependencies: [
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "TarwinGPUTests",
      dependencies: [
        "TarwinGPU", .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ], path: "tests/TarwinGPUTests"),
  ]
)
