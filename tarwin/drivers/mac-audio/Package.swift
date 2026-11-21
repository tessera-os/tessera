// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MacAudio", platforms: [.macOS(.v26)],
  products: [
    .library(name: "MacAudioWire", targets: ["MacAudioWire"]),
    .library(name: "MacAudioHost", targets: ["MacAudioHost"]),
    .library(name: "MacAudioDriver", targets: ["MacAudioDriver"]),
  ],
  dependencies: [.package(path: "../mac-hid"), .package(path: "../../tarwin-arch-hosted")],
  targets: [
    .target(name: "MacAudioWire", dependencies: [.product(name: "HostedDeviceWire", package: "mac-hid"),
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")]),
    .target(name: "MacAudioHost", dependencies: ["MacAudioWire"]),
    .target(name: "MacAudioDriver", dependencies: ["MacAudioWire", .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")]),
    .testTarget(name: "MacAudioTests", dependencies: ["MacAudioHost", "MacAudioDriver"], path: "tests/MacAudioTests"),
  ])
