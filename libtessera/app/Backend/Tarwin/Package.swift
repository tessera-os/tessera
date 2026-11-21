// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LibTesseraTarwin",
  platforms: [.macOS(.v15)],
  products: [.library(name: "LibTesseraTarwin", targets: ["LibTesseraTarwin"])],
  dependencies: [
    .package(path: "../../../../tarwin/tarwin-syscall"),
    .package(path: "../../../../tarwin/tarwin-object"),
    .package(path: "../../../../tarwin/tarwin-sync"),
    .package(name: "TarwinProviders", path: "../../../../tarwin/tarwin-syscall/providers"),
  ],
  targets: [
    .target(
      name: "LibTesseraTarwin",
      dependencies: [.product(name: "TarwinABI", package: "tarwin-syscall")],
      path: ".", exclude: ["tests", "variants", "random-backend", "ring-backend"],
      sources: [
        "CallNumbers.swift", "NativeEntry.swift", "NativeHandles.swift", "NativeSync.swift",
        "NativeHardwareGate.swift", "NativeProcess.swift", "NativeChannels.swift", "NativeEvents.swift",
        "NativePorts.swift",
      ]),
    .testTarget(
      name: "NativeEntryTests",
      dependencies: [
        "LibTesseraTarwin", .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinObjectCalls", package: "TarwinProviders"),
        .product(name: "TarwinSync", package: "tarwin-sync"),
        .product(name: "TarwinSyncCalls", package: "TarwinProviders"),
      ], path: "tests"),
  ])
