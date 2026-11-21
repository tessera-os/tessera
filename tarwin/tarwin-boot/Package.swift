// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinBoot",
  platforms: [.macOS(.v13)],
  products: [.library(name: "TarwinBoot", targets: ["TarwinBoot"])],
  dependencies: [.package(path: "../kcore")],
  targets: [
    .target(name: "TarwinBoot", dependencies: [.product(name: "KCore", package: "kcore")]),
    .testTarget(
      name: "TarwinBootTests", dependencies: ["TarwinBoot"], path: "tests/TarwinBootTests"),
  ]
)
