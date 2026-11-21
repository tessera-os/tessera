// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinMM",
  platforms: [.macOS(.v13)],
  products: [.library(name: "TarwinMM", targets: ["TarwinMM"])],
  dependencies: [.package(path: "../kcore")],
  targets: [
    .target(name: "TarwinMM", dependencies: [.product(name: "KCore", package: "kcore")]),
    .testTarget(name: "TarwinMMTests", dependencies: ["TarwinMM"], path: "tests/TarwinMMTests"),
  ]
)
