// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Tarboot",
  platforms: [.macOS(.v13)],
  products: [.library(name: "Tarboot", targets: ["Tarboot"])],
  dependencies: [.package(path: "../kcore")],
  targets: [
    .target(name: "Tarboot", dependencies: [.product(name: "KCore", package: "kcore")]),
    .testTarget(name: "TarbootTests", dependencies: ["Tarboot"], path: "tests/TarbootTests"),
  ]
)
