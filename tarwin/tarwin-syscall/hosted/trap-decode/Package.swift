// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinTrapDecode",
  products: [.library(name: "TarwinTrapDecode", targets: ["TarwinTrapDecode"])],
  targets: [
    .target(name: "TarwinTrapDecode"),
    .testTarget(name: "TarwinTrapDecodeTests", dependencies: ["TarwinTrapDecode"]),
  ])
