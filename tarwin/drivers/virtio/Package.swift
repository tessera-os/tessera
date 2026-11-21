// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "VirtioGuest", platforms: [.macOS(.v26)],
  products: [
    .library(name: "VirtioNetService", targets: ["VirtioNetService"]),
    .library(name: "VirtioBlockService", targets: ["VirtioBlockService"]),
    .library(name: "VirtioGuest", targets: ["VirtioGuest"]),
  ],
  dependencies: [
    .package(path: "../../tarwin-net"), .package(path: "../../tarwin-block"),
    .package(path: "../../tarwin-ipc"),
  ],
  targets: [
    .target(
      name: "VirtioNetService",
      dependencies: [
        "VirtioGuest", .product(name: "TarwinNetWire", package: "tarwin-net"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ]),
    .target(name: "VirtioGuest", dependencies: []),
    .target(
      name: "VirtioBlockService",
      dependencies: [
        "VirtioGuest", .product(name: "TarwinBlockWire", package: "tarwin-block"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ]),
    .testTarget(
      name: "VirtioGuestTests",
      dependencies: ["VirtioGuest", "VirtioBlockService", "VirtioNetService"],
      path: "tests/VirtioGuestTests"),
  ]
)
