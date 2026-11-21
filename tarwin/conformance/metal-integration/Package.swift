import Foundation
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MetalIntegration", platforms: [.macOS(.v13)],
  dependencies: [
    .package(path: "../../tvmm"),
    .package(
      name: "TvGpuGuest",
      path: ProcessInfo.processInfo.environment["TVGPU_PACKAGE"] ?? "../../drivers/tvgpu"),
  ],
  targets: [
    .executableTarget(
      name: "metal-present-check",
      dependencies: [
        .product(name: "TVMM", package: "tvmm"),
        .product(name: "TvGpuGuest", package: "TvGpuGuest"),
        .product(name: "MosaicMetal", package: "TvGpuGuest"),
      ])
  ]
)
