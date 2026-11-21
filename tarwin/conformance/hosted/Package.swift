// swift-tools-version: 6.0
import Foundation
import PackageDescription

let hosted = ProcessInfo.processInfo.environment["TARWIN_HOSTED_ROOT"] ?? "../../../tessera/build/tarwin-hosted"
let package = Package(
  name: "TarwinHostedConformance", platforms: [.macOS("26.0")],
  dependencies: [.package(path: hosted)],
  targets: [.testTarget(name: "HostedConformanceTests", dependencies: [
    .product(name: "TarwindKernel", package: "tarwin-hosted"),
  ])], swiftLanguageModes: [.v6])
