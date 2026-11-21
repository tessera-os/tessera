// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinRandom", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinRandomCore", targets: ["TarwinRandomCore"]),
    .library(name: "TarwinKernelRandom", targets: ["TarwinKernelRandom"]),
    .library(name: "TarwinProcessKeys", targets: ["TarwinProcessKeys"]),
    .library(name: "TarwinRandomCalls", targets: ["TarwinRandomCalls"]),
  ], dependencies: [
    .package(path: "../../tarwin-loader"), .package(path: "../../tarwin-syscall"),
    .package(path: "../../tarwin-object"),
  ],
  targets: [
    .target(name: "TarwinRandomCore"),
    .target(
      name: "TarwinProcessKeys",
      dependencies: [
        "TarwinKernelRandom", "TarwinRandomCore",
        .product(name: "TarwinObject", package: "tarwin-object"),
      ], swiftSettings: [.enableExperimentalFeature("Volatile")]),
    .target(
      name: "TarwinRandomCalls",
      dependencies: [
        "TarwinRandomCore",
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
    .target(
      name: "TarwinKernelRandom",
      dependencies: [
        "TarwinRandomCore",
        .product(name: "TarwinLoader", package: "tarwin-loader"),
      ]),
    .testTarget(
      name: "TarwinRandomTests",
      dependencies: [
        "TarwinRandomCore", "TarwinKernelRandom", "TarwinProcessKeys",
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinLoader", package: "tarwin-loader"),
      ]),
  ])
