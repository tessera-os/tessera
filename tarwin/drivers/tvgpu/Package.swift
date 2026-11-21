// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TvGpuGuest",
  products: [.library(name: "TvGpuGuest", targets: ["TvGpuGuest"])],
  dependencies: [],
  targets: [
    .target(name: "TvGpuGuest", dependencies: []),
    .testTarget(name: "TvGpuGuestTests", dependencies: ["TvGpuGuest"]),
  ]
)
