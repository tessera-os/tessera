// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinIPC", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinIPC", targets: ["TarwinIPC"])],
  targets: [
    .target(name: "TarwinIPC"),
    .testTarget(name: "TarwinIPCTests", dependencies: ["TarwinIPC"], path: "tests/TarwinIPCTests"),
  ])
