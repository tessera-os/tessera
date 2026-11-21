// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinHV",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "TarwinHV", targets: ["TarwinHV"]),
    .library(name: "TarwinHVCalls", targets: ["TarwinHVCalls"]),
  ],
  dependencies: [.package(path: "../tarwin-syscall"), .package(path: "../tarwin-object")],
  targets: [
    .target(
      name: "TarwinHV", dependencies: [.product(name: "TarwinSyscall", package: "tarwin-syscall")]),
    .target(
      name: "TarwinHVCalls",
      dependencies: [
        "TarwinHV", .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "TarwinHVCallTests", dependencies: ["TarwinHVCalls"], path: "tests/TarwinHVCallTests"),
    .testTarget(name: "TarwinHVTests", dependencies: ["TarwinHV"], path: "tests/TarwinHVTests"),
  ]
)
