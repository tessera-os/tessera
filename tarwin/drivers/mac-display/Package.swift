// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MacDisplay",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "MacDisplay", targets: ["MacDisplay"]),
    .executable(name: "mac-display-demo", targets: ["MacDisplayDemo"]),
  ],
  dependencies: [
    .package(path: "../metal-gpu"),
    .package(path: "../tvgpu"),
    .package(path: "../../tarwin-gpu"),
  ],
  targets: [
    .target(
      name: "MacDisplay", dependencies: [.product(name: "HostedMetalGPU", package: "metal-gpu")]),
    .executableTarget(
      name: "MacDisplayDemo",
      dependencies: [
        "MacDisplay", .product(name: "HostedMetalGPU", package: "metal-gpu"),
        .product(name: "TvGpuGuest", package: "tvgpu"),
        .product(name: "TarwinGPU", package: "tarwin-gpu"),
      ]),
    .testTarget(
      name: "MacDisplayTests",
      dependencies: [
        "MacDisplay", .product(name: "HostedMetalGPU", package: "metal-gpu"),
        .product(name: "TvGpuGuest", package: "tvgpu"),
        .product(name: "TarwinGPU", package: "tarwin-gpu"),
      ]),
  ]
)
