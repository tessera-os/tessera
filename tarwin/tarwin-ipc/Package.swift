// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinIPC", products: [.library(name: "TarwinIPC", targets: ["TarwinIPC"])],
  targets: [
    .target(name: "TarwinIPC"),
    .testTarget(name: "TarwinIPCTests", dependencies: ["TarwinIPC"], path: "tests/TarwinIPCTests"),
  ])
