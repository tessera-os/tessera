// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinChannelCalls", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinChannelCalls", targets: ["TarwinChannelCalls"])],
  dependencies: [
    .package(name: "TarwinSyscall", path: ".."),
    .package(path: "../../tarwin-ipc"), .package(path: "../../tarwin-object"),
  ],
  targets: [
    .target(
      name: "TarwinChannelCalls",
      dependencies: [
        .product(name: "TarwinSyscall", package: "TarwinSyscall"),
        .product(name: "TarwinABI", package: "TarwinSyscall"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinIPCChannels", package: "tarwin-ipc"),
      ]),
    .testTarget(name: "TarwinChannelCallTests", dependencies: ["TarwinChannelCalls"]),
  ])
