// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinLoader",
  platforms: [.macOS(.v12)],
  products: [
    .library(name: "TarwinLoader", targets: ["TarwinLoader"]),
    .executable(name: "inspect-unsigned", targets: ["InspectUnsigned"]),
    .executable(name: "sign-fixture", targets: ["SignFixture"]),
  ],
  targets: [
    .target(name: "TarwinLoader"),
    .executableTarget(name: "SignFixture", dependencies: ["TarwinLoader"]),
    .executableTarget(
      name: "InspectUnsigned", dependencies: ["TarwinLoader"], path: "tests/InspectUnsigned"),
    .testTarget(
      name: "TarwinLoaderTests", dependencies: ["TarwinLoader"], path: "tests/TarwinLoaderTests",
      resources: [.copy("Fixtures")]),
  ])
