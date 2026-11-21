// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "BlockQTest", platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../.."), .package(path: "../../../../tarwin-block"),
    .package(path: "../../../../tarwin-device"), .package(path: "../../../../tarwin-ipc"),
  ],
  targets: [
    .executableTarget(
      name: "BlockQTest",
      dependencies: [
        .product(name: "TarwinBlock", package: "tarwin-block"),
        .product(name: "TarwinDevice", package: "tarwin-device"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "VirtioBlockService", package: "virtio"),
        .product(name: "VirtioGuest", package: "virtio"),
      ])
  ])
