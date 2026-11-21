// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinHV",
  platforms: [.macOS("26.0")],
  products: [.library(name: "TarwinHV", targets: ["TarwinHV"])],
  dependencies: [.package(path: "../tarwin-syscall")],
  targets: [
    .target(
      name: "TarwinHV", dependencies: [.product(name: "TarwinSyscall", package: "tarwin-syscall")]),
    .testTarget(name: "TarwinHVTests", dependencies: ["TarwinHV"], path: "tests/TarwinHVTests"),
  ]
)
