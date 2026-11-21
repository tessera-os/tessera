// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinConformance",
  targets: [
    .target(name: "Acceptance"),
    .executableTarget(name: "tarwin-conformance", dependencies: ["Acceptance"]),
    .testTarget(
      name: "AcceptanceTests", dependencies: ["Acceptance"], path: "tests/AcceptanceTests"),
  ])
