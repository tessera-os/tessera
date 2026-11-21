// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinSyscall",
  products: [
    .library(name: "TarwinSyscall", targets: ["TarwinSyscall"]),
    .executable(name: "call-index", targets: ["CallIndex"]),
  ],
  targets: [
    .target(name: "TarwinSyscall"), .executableTarget(name: "CallIndex"),
    .testTarget(
      name: "TarwinSyscallTests", dependencies: ["TarwinSyscall"], path: "tests/TarwinSyscallTests"),
    .testTarget(name: "CallIndexTests", dependencies: ["CallIndex"], path: "tests/CallIndexTests"),
  ])
