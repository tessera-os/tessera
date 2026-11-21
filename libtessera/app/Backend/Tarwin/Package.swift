// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LibTesseraTarwin",
  products: [.library(name: "LibTesseraTarwin", targets: ["LibTesseraTarwin"])],
  dependencies: [.package(path: "../../../../tarwin/tarwin-syscall")],
  targets: [
    .target(
      name: "LibTesseraTarwin",
      dependencies: [.product(name: "TarwinABI", package: "tarwin-syscall")],
      path: ".", exclude: ["tests"], sources: ["CallNumbers.swift", "NativeEntry.swift"]),
    .testTarget(
      name: "NativeEntryTests",
      dependencies: [
        "LibTesseraTarwin", .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ], path: "tests"),
  ])
