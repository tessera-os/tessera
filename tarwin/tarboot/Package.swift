// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Tarboot",
  platforms: [.macOS(.v13)],
  products: [.library(name: "Tarboot", targets: ["Tarboot"])],
  dependencies: [.package(path: "../kcore"), .package(path: "../tarwin-boot")],
  targets: [
    .target(name: "Tarboot", dependencies: [
      .product(name: "KCore", package: "kcore"), .product(name: "TarwinBoot", package: "tarwin-boot"),
    ]),
    .testTarget(name: "TarbootTests", dependencies: ["Tarboot"], path: "tests/TarbootTests"),
  ]
)
