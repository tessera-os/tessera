// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinTrace",
  platforms: [.macOS("26.0")],
  products: [.library(name: "TarwinTrace", targets: ["TarwinTrace"])],
  dependencies: [.package(path: "../tarwin-syscall")],
  targets: [
    .target(
      name: "TarwinTrace",
      dependencies: [.product(name: "TarwinSyscall", package: "tarwin-syscall")]),
    .testTarget(
      name: "TarwinTraceTests", dependencies: ["TarwinTrace"], path: "tests/TarwinTraceTests"),
  ]
)
