// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TvGpuGuest",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "TvGpuGuest", targets: ["TvGpuGuest"]),
    .library(name: "MosaicMetal", targets: ["MosaicMetal"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "TvGpuGuest", dependencies: []),
    .target(name: "MosaicMetal", dependencies: ["TvGpuGuest"]),
    .testTarget(name: "MosaicMetalTests", dependencies: ["MosaicMetal", "TvGpuGuest"]),
    .testTarget(name: "TvGpuGuestTests", dependencies: ["TvGpuGuest"]),
  ]
)
