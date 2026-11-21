// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinSyscall",
  products: [
    .library(name: "TarwinABI", targets: ["TarwinABI"]),
    .library(name: "TarwinSyscall", targets: ["TarwinSyscall"]),
    .executable(name: "call-index", targets: ["CallIndex"]),
  ],
  targets: [
    .target(name: "TarwinABI"), .target(name: "TarwinSyscall", dependencies: ["TarwinABI"]),
    .executableTarget(name: "CallIndex"),
    .testTarget(
      name: "TarwinSyscallTests", dependencies: ["TarwinSyscall"], path: "tests/TarwinSyscallTests"),
    .testTarget(name: "CallIndexTests", dependencies: ["CallIndex"], path: "tests/CallIndexTests"),
  ])
