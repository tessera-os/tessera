// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MacHID", platforms: [.macOS(.v26)],
  products: [
    .library(name: "HostedDeviceWire", targets: ["HostedDeviceWire"]),
    .library(name: "MacHIDCapture", targets: ["MacHIDCapture"]),
    .library(name: "MacHIDDriver", targets: ["MacHIDDriver"]),
  ],
  dependencies: [.package(path: "../../tarwin-arch-hosted")],
  targets: [
    .target(name: "HostedDeviceWire", dependencies: [.product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")]),
    .target(name: "MacHIDCapture", dependencies: ["HostedDeviceWire", .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")]),
    .target(name: "MacHIDDriver", dependencies: ["HostedDeviceWire", .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")]),
    .testTarget(name: "MacHIDTests", dependencies: ["HostedDeviceWire", "MacHIDCapture", "MacHIDDriver"], path: "tests/MacHIDTests"),
  ])
