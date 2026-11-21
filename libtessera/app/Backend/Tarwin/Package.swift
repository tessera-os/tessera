// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LibTesseraTarwin",
  platforms: [.macOS(.v15)],
  products: [.library(name: "LibTesseraTarwin", targets: ["LibTesseraTarwin"])],
  dependencies: [
    .package(path: "../../../../tarwin/tarwin-syscall"),
    .package(path: "../../../../tarwin/tarwin-object"),
  ],
  targets: [
    .target(
      name: "LibTesseraTarwin",
      dependencies: [.product(name: "TarwinABI", package: "tarwin-syscall")],
      path: ".", exclude: ["tests"],
      sources: ["CallNumbers.swift", "NativeEntry.swift", "NativeHandles.swift"]),
    .testTarget(
      name: "NativeEntryTests",
      dependencies: [
        "LibTesseraTarwin", .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinObjectCalls", package: "tarwin-object"),
      ], path: "tests"),
  ])
