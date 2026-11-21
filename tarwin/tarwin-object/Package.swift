// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinObject", platforms: [.macOS(.v15)],
  products: [
    .library(name: "TarwinObject", targets: ["TarwinObject"]),
    .library(name: "TarwinObjectCalls", targets: ["TarwinObjectCalls"]),
  ],
  dependencies: [
    .package(path: "../tarwin-syscall")
  ],
  targets: [
    .target(name: "TarwinObject"),
    .target(
      name: "TarwinObjectCalls",
      dependencies: [
        "TarwinObject", .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "TarwinObjectTests",
      dependencies: ["TarwinObject"], path: "tests/TarwinObjectTests"),
  ])
