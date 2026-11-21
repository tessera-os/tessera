// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MacPower", platforms: [.macOS(.v26)],
  products: [
    .library(name: "MacPowerWire", targets: ["MacPowerWire"]),
    .library(name: "MacPowerHost", targets: ["MacPowerHost"]),
    .library(name: "MacPowerDriver", targets: ["MacPowerDriver"]),
  ],
  dependencies: [.package(path: "../mac-hid"), .package(path: "../../tarwin-power"),
    .package(path: "../../tarwin-arch-hosted")],
  targets: [
    .target(name: "MacPowerWire", dependencies: [.product(name: "HostedDeviceWire", package: "mac-hid"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")]),
    .target(name: "MacPowerHost", dependencies: ["MacPowerWire"]),
    .target(name: "MacPowerDriver", dependencies: ["MacPowerWire", .product(name: "TarwinPower", package: "tarwin-power"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")]),
    .testTarget(name: "MacPowerTests", dependencies: ["MacPowerHost", "MacPowerDriver"], path: "tests/MacPowerTests"),
  ])
