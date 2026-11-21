// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinProbe",
  products: [.library(name: "TarwinProbe", targets: ["TarwinProbe"])],
  dependencies: [.package(path: "../tarwin-syscall")],
  targets: [
    .target(
      name: "TarwinProbe",
      dependencies: [.product(name: "TarwinSyscall", package: "tarwin-syscall")]),
    .testTarget(
      name: "TarwinProbeTests", dependencies: ["TarwinProbe"], path: "tests/TarwinProbeTests"),
  ]
)
