// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinW0Verify", platforms: [.macOS(.v26)],
  products: [.library(name: "TarwinW0Verify", targets: ["TarwinW0Verify"])],
  dependencies: [.package(name: "TarwinLoader", path: "..")],
  targets: [
    .target(name: "TarwinW0Verify", dependencies: ["TarwinLoader"]),
    .testTarget(
      name: "TarwinW0Tests", dependencies: ["TarwinW0Verify"], resources: [.copy("acvp-43.json")]),
  ])
