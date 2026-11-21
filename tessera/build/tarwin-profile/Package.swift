// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "TarwinProfileCheck", platforms: [.macOS(.v15)],
  products: [.executable(name: "tarwin-profile-check", targets: ["TarwinProfileCheck"])],
  dependencies: [.package(path: "../../../../languages/swift"), .package(path: "../../../../languages/klf-swift")],
  targets: [
    .executableTarget(name: "TarwinProfileCheck", dependencies: [
      .product(name: "SwiftLanguage", package: "swift"), .product(name: "KLFLanguage", package: "klf-swift"),
      .product(name: "TIR", package: "klf-swift")]),
    .testTarget(name: "TarwinProfileCheckTests", dependencies: ["TarwinProfileCheck", .product(name: "TIR", package: "klf-swift")])
  ])
