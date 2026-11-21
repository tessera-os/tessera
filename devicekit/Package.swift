// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NativeDriverKit",
  platforms: [.macOS(.v15)],
  products: [.library(name: "NativeDriverKit", targets: ["NativeDriverKit"])],
  dependencies: [
    .package(name: "LibTesseraTarwin", path: "../libtessera/app/Backend/Tarwin"),
    .package(path: "../tarwin/tarwin-syscall"),
  ],
  targets: [
    .target(
      name: "NativeDriverKit", dependencies: ["LibTesseraTarwin"],
      path: "tarwin/Sources/NativeDriverKit"),
    .testTarget(
      name: "NativeDriverKitTests",
      dependencies: [
        "NativeDriverKit", "LibTesseraTarwin",
        .product(name: "TarwinABI", package: "tarwin-syscall"),
      ],
      path: "tarwin/tests/NativeDriverKitTests"),
  ]
)
