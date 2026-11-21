// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TarwinArchHosted", platforms: [.macOS(.v15)],
  products: [.library(name: "TarwinArchHosted", targets: ["TarwinArchHosted"])],
  targets: [
    .target(name: "CHostDarwin", exclude: ["HostedException.defs"]),
    .target(name: "TarwinArchHosted", dependencies: ["CHostDarwin"]),
    .executableTarget(name: "HostedExceptionProbe", dependencies: ["TarwinArchHosted", "CHostDarwin"]),
    .testTarget(name: "TarwinArchHostedTests", dependencies: ["TarwinArchHosted", "HostedExceptionProbe"]),
  ],
  swiftLanguageModes: [.v6])
