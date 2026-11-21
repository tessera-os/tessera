// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ProbeAnalysis",
  products: [.library(name: "ProbeAnalysis", targets: ["ProbeAnalysis"])],
  dependencies: [.package(path: "..")],
  targets: [
    .target(
      name: "ProbeAnalysis", dependencies: [.product(name: "TarwinProbe", package: "tarwin-probe")]),
    .testTarget(
      name: "ProbeAnalysisTests", dependencies: ["ProbeAnalysis"], path: "tests/ProbeAnalysisTests"),
  ]
)
