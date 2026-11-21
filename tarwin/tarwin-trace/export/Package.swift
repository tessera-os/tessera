// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PerfettoExport",
  products: [.library(name: "PerfettoExport", targets: ["PerfettoExport"])],
  dependencies: [],
  targets: [
    .target(name: "PerfettoExport", dependencies: []),
    .testTarget(
      name: "PerfettoExportTests", dependencies: ["PerfettoExport"],
      path: "tests/PerfettoExportTests"),
  ]
)
