// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "LibTesseraRandom", platforms: [.macOS(.v26)],
  products: [
    .library(name: "LibTesseraRandom", targets: ["LibTesseraRandom"])
  ],
  dependencies: [
    .package(name: "LibTesseraTarwin", path: ".."),
    .package(name: "TarwinRandom", path: "../../../../../tarwin/tarwin-security/random"),
    .package(path: "../../../../../tarwin/tarwin-syscall"),
  ],
  targets: [
    .target(
      name: "LibTesseraRandom",
      dependencies: [
        "LibTesseraTarwin",
        .product(name: "TarwinRandomCore", package: "TarwinRandom"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "NativeRandomTests",
      dependencies: [
        "LibTesseraRandom", "LibTesseraTarwin",
        .product(name: "TarwinRandomCore", package: "TarwinRandom"),
        .product(name: "TarwinRandomCalls", package: "TarwinRandom"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ]),
  ])
