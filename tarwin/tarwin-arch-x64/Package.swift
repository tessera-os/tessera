// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinArchX64",
  platforms: [.macOS(.v13)],
  products: [.library(name: "TarwinArchX64", targets: ["TarwinArchX64"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinArchX64", dependencies: []),
    .testTarget(
      name: "TarwinArchX64Tests", dependencies: ["TarwinArchX64"], path: "tests/TarwinArchX64Tests"),
  ]
)
