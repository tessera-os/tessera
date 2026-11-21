// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "LibTesseraPortRings", platforms: [.macOS(.v26)],
  products: [.library(name: "LibTesseraPortRings", targets: ["LibTesseraPortRings"])],
  dependencies: [
    .package(name: "LibTesseraTarwin", path: ".."),
    .package(path: "../../../../../tarwin/tarwin-ipc"),
    .package(path: "../../../../../tarwin/tarwin-syscall"),
  ],
  targets: [
    .target(
      name: "LibTesseraPortRings",
      dependencies: [
        "LibTesseraTarwin", .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "NativeRingTests",
      dependencies: [
        "LibTesseraPortRings", "LibTesseraTarwin",
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ]),
  ])
