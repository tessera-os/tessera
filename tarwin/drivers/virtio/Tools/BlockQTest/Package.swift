// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BlockQTest", platforms: [.macOS(.v13)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "BlockQTest", dependencies: [.product(name: "VirtioGuest", package: "virtio")])
  ])
