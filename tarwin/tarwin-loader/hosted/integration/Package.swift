// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "HostedLoaderIntegration",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../TarwinLoaderHosted"),
    .package(path: "../../../tarwin-mm/hosted/TarwinMMHosted"),
    .package(path: "../../../../libtessera/app/Backend/Tarwin/hosted/TarwinHostedImage"),
  ],
  targets: [
    .testTarget(name: "HostedLoaderIntegrationTests", dependencies: [
      .product(name: "TarwinLoaderHosted", package: "TarwinLoaderHosted"),
      .product(name: "TarwinMMHosted", package: "TarwinMMHosted"),
      .product(name: "TarwinHostedImage", package: "TarwinHostedImage"),
    ]),
  ]
)
