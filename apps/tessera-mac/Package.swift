// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "TesseraMac", platforms: [.macOS(.v26)], products: [
    .library(name: "TesseraHostKit", targets: ["TesseraHostKit"]),
    .executable(name: "Tessera", targets: ["Tessera"]),
    .executable(name: "tarwind", targets: ["tarwind"]),
    .executable(name: "tessera-mac-test", targets: ["tessera-mac-test"])
], dependencies: [
    .package(path: "../../tarwin/drivers/mac-hid"),
    .package(path: "../../tarwin/drivers/mac-audio"),
    .package(path: "../../tarwin/drivers/mac-power"),
    .package(path: "../../tarwin/tarwin-arch-hosted")
], targets: [
    .target(name: "TesseraHostKit", dependencies: [
        .product(name: "HostedDeviceWire", package: "mac-hid"),
        .product(name: "MacHIDDriver", package: "mac-hid"),
        .product(name: "MacAudioDriver", package: "mac-audio"),
        .product(name: "MacPowerDriver", package: "mac-power"),
        .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")
    ]),
    .executableTarget(name: "tarwind", dependencies: ["TesseraHostKit"]),
    .executableTarget(name: "Tessera", dependencies: ["TesseraHostKit",
        .product(name: "MacHIDCapture", package: "mac-hid"),
        .product(name: "MacAudioHost", package: "mac-audio"),
        .product(name: "MacPowerHost", package: "mac-power")]),
    .executableTarget(name: "tessera-mac-test", dependencies: ["TesseraHostKit"]),
    .testTarget(name: "TesseraHostKitTests", dependencies: ["TesseraHostKit"])
], swiftLanguageModes: [.v5])
