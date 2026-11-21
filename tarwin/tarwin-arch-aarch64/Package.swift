// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinArchAarch64",
  platforms: [.macOS(.v13)],
  products: [.library(name: "TarwinArchAarch64", targets: ["TarwinArchAarch64"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinArchAarch64", dependencies: []),
    .testTarget(
      name: "TarwinArchAarch64Tests", dependencies: ["TarwinArchAarch64"],
      path: "tests/TarwinArchAarch64Tests"),
  ]
)
