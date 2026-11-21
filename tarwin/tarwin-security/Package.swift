// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinSecurity", products: [.library(name: "TarwinSecurity", targets: ["TarwinSecurity"])],
  targets: [
    .target(name: "TarwinSecurity"),
    .testTarget(
      name: "TarwinSecurityTests", dependencies: ["TarwinSecurity"],
      path: "tests/TarwinSecurityTests"),
  ])
