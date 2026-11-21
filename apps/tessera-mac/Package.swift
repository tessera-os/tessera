// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "TesseraMac", platforms: [.macOS(.v26)], products: [
    .library(name: "TesseraHostKit", targets: ["TesseraHostKit"]),
    .executable(name: "Tessera", targets: ["Tessera"]),
    .executable(name: "tarwind", targets: ["tarwind"]),
    .executable(name: "tessera-mac-test", targets: ["tessera-mac-test"])
], targets: [
    .target(name: "TesseraHostKit"),
    .executableTarget(name: "tarwind", dependencies: ["TesseraHostKit"]),
    .executableTarget(name: "tarwin-task"),
    .executableTarget(name: "Tessera", dependencies: ["TesseraHostKit"]),
    .executableTarget(name: "tessera-mac-test", dependencies: ["TesseraHostKit"]),
    .testTarget(name: "TesseraHostKitTests", dependencies: ["TesseraHostKit"])
], swiftLanguageModes: [.v5])
