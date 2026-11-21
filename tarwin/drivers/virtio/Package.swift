// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "VirtioGuest",
  products: [.library(name: "VirtioGuest", targets: ["VirtioGuest"])],
  dependencies: [],
  targets: [
    .target(name: "VirtioGuest", dependencies: []),
    .testTarget(name: "VirtioGuestTests", dependencies: ["VirtioGuest"]),
  ]
)
