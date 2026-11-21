// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "NVMeDriver", platforms: [.macOS(.v26)],
  products: [.library(name: "NVMeDriver", targets: ["NVMeDriver"])],
  dependencies: [.package(path: "../../tarwin-block"), .package(path: "../../tarwin-ipc")],
  targets: [
    .target(
      name: "NVMeDriver",
      dependencies: [
        .product(name: "TarwinBlockWire", package: "tarwin-block"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
      ]),
    .testTarget(
      name: "NVMeDriverTests", dependencies: ["NVMeDriver"], path: "tests/NVMeDriverTests"),
  ])
