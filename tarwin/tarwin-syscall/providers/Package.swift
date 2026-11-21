// swift-tools-version: 6.0
import PackageDescription

// Keep the ABI-only package usable by handlers that do not need OS atomics.
let package = Package(
  name: "TarwinProviders", platforms: [.macOS(.v15)],
  products: [
    .library(name: "TarwinObjectCalls", targets: ["TarwinObjectCalls"]),
    .library(name: "TarwinSyncCalls", targets: ["TarwinSyncCalls"]),
  ],
  dependencies: [
    .package(name: "TarwinSyscall", path: ".."),
    .package(path: "../../tarwin-object"),
    .package(path: "../../tarwin-sync"),
  ],
  targets: [
    .target(
      name: "TarwinObjectCalls",
      dependencies: [
        .product(name: "TarwinABI", package: "TarwinSyscall"),
        .product(name: "TarwinSyscall", package: "TarwinSyscall"),
        .product(name: "TarwinObject", package: "tarwin-object"),
      ]),
    .target(
      name: "TarwinSyncCalls",
      dependencies: [
        .product(name: "TarwinABI", package: "TarwinSyscall"),
        .product(name: "TarwinSyscall", package: "TarwinSyscall"),
        .product(name: "TarwinSync", package: "tarwin-sync"),
      ]),
  ])
