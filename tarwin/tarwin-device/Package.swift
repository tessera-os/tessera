// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinDevice",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinIoCompletion", targets: ["TarwinIoCompletion"]),
    .library(name: "TarwinDevice", targets: ["TarwinDevice"]),
  ],
  dependencies: [
    .package(path: "../kcore"), .package(path: "../tarwin-boot"), .package(path: "../tarwin-ipc"),
    .package(path: "../tarwin-object"),
    .package(path: "../tarwin-syscall"),
  ],
  targets: [
    .target(
      name: "TarwinIoCompletion", dependencies: [.product(name: "TarwinIPC", package: "tarwin-ipc")]
    ),
    .target(
      name: "TarwinDevice",
      dependencies: [
        "TarwinIoCompletion", .product(name: "KCore", package: "kcore"),
        .product(name: "TarwinBoot", package: "tarwin-boot"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "TarwinDeviceTests",
      dependencies: [
        "TarwinDevice", "TarwinIoCompletion", .product(name: "KCore", package: "kcore"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ], path: "tests/TarwinDeviceTests"),
  ]
)
