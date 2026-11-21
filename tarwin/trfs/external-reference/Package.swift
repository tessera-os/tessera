// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TRFSExternalReference", platforms: [.macOS(.v26)],
  dependencies: [.package(path: "..")],
  targets: [
    .testTarget(
      name: "ExternalReferenceTests",
      dependencies: [.product(name: "TRFS", package: "trfs")],
      path: "Tests/ExternalReferenceTests")
  ]
)
