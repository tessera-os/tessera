// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PerfettoExport",
  platforms: [.macOS("26.0")],
  products: [.library(name: "PerfettoExport", targets: ["PerfettoExport"])],
  dependencies: [.package(path: "..")],
  targets: [
    .target(
      name: "PerfettoExport", dependencies: [.product(name: "TarwinTrace", package: "tarwin-trace")]
    ),
    .testTarget(
      name: "PerfettoExportTests", dependencies: ["PerfettoExport"],
      path: "tests/PerfettoExportTests"),
  ]
)
