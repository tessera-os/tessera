// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "USBMassStorage", platforms: [.macOS(.v26)],
  products: [.library(name: "USBMassStorage", targets: ["USBMassStorage"])],
  dependencies: [
    .package(path: "../../tarwin-block"), .package(path: "../../tarwin-ipc"),
    .package(path: "../../tarwin-device"),
  ],
  targets: [
    .target(
      name: "USBMassStorage",
      dependencies: [
        .product(name: "TarwinBlockWire", package: "tarwin-block"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ]),
    .testTarget(
      name: "USBMassStorageTests",
      dependencies: [
        "USBMassStorage", .product(name: "TarwinDevice", package: "tarwin-device"),
        .product(name: "TarwinIoCompletion", package: "tarwin-device"),
        .product(name: "TarwinBlock", package: "tarwin-block"),
      ]),
  ]
)
