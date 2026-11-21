// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinArchRv64",
  platforms: [.macOS(.v13)],
  products: [.library(name: "TarwinArchRv64", targets: ["TarwinArchRv64"])],
  dependencies: [],
  targets: [
    .target(name: "TarwinArchRv64", dependencies: []),
    .testTarget(
      name: "TarwinArchRv64Tests", dependencies: ["TarwinArchRv64"],
      path: "tests/TarwinArchRv64Tests"),
  ]
)
