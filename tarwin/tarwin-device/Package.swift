// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinDevice",
  platforms: [.macOS(.v15)],
  products: [.library(name: "TarwinDevice", targets: ["TarwinDevice"])],
  dependencies: [.package(path: "../tarwin-object"), .package(path: "../tarwin-syscall")],
  targets: [
    .target(
      name: "TarwinDevice",
      dependencies: [
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      ]),
    .testTarget(
      name: "TarwinDeviceTests", dependencies: ["TarwinDevice"], path: "tests/TarwinDeviceTests"),
  ]
)
