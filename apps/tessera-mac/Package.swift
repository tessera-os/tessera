// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "TesseraMac", platforms: [.macOS(.v26)], products: [
    .library(name: "TesseraHostKit", targets: ["TesseraHostKit"]),
    .executable(name: "Tessera", targets: ["Tessera"]),
    .executable(name: "tarwind", targets: ["tarwind"]),
    .executable(name: "tessera-pack-system", targets: ["tessera-pack-system"]),
    .executable(name: "tessera-mac-test", targets: ["tessera-mac-test"])
], dependencies: [
    .package(path: "../../tessera/build/tarwin-hosted"),
    .package(path: "../../tarwin/tarwin-task"),
    .package(path: "../../tarwin/tarwin-syscall"),
    .package(path: "../../tarwin/tarwin-syscall/hosted"),
    .package(path: "../../tarwin/drivers/mac-hid"),
    .package(path: "../../tarwin/drivers/mac-audio"),
    .package(path: "../../tarwin/drivers/mac-power"),
    .package(path: "../../tarwin/drivers/metal-gpu"),
    .package(path: "../../tarwin/drivers/mac-display"),
    .package(path: "../../tarwin/tarwin-gpu"),
    .package(path: "../../tarwin/tarwin-block/hosted/tarwin-block-hosted"),
    .package(path: "../../tarwin/trfs"),
    .package(path: "../../tarwin/trfs/hosted/trfs-hosted"),
    .package(path: "../../tarwin/tarwin-arch-hosted")
], targets: [
    .target(name: "HostedSystemImage", dependencies: [
        .product(name: "TarwinBlockHosted", package: "tarwin-block-hosted"),
        .product(name: "TRFS", package: "trfs"),
        .product(name: "TRFSHosted", package: "trfs-hosted")
    ]),
    .executableTarget(name: "tessera-pack-system", dependencies: ["HostedSystemImage"]),
    .testTarget(name: "HostedSystemImageTests", dependencies: ["HostedSystemImage",
        .product(name: "TRFSHosted", package: "trfs-hosted")
    ]),
    .target(name: "TesseraHostKit", dependencies: [
        .product(name: "TarwindKernel", package: "tarwin-hosted"),
        .product(name: "TarwinTaskTransport", package: "tarwin-task"),
        .product(name: "TarwinTaskProtocol", package: "tarwin-task"),
        .product(name: "TarwinHostedGate", package: "hosted"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "HostedDeviceWire", package: "mac-hid"),
        .product(name: "MacHIDCapture", package: "mac-hid"),
        .product(name: "MacHIDDriver", package: "mac-hid"),
        .product(name: "MacAudioDriver", package: "mac-audio"),
        .product(name: "MacPowerDriver", package: "mac-power"),
        .product(name: "HostedMetalGPU", package: "metal-gpu"),
        .product(name: "MacDisplay", package: "mac-display"),
        .product(name: "TarwinGPU", package: "tarwin-gpu"),
        .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted")
    ]),
    .executableTarget(name: "tarwind", dependencies: ["TesseraHostKit"]),
    .executableTarget(name: "tessera-test-task", dependencies: ["TesseraHostKit"]),
    .executableTarget(name: "Tessera", dependencies: ["TesseraHostKit",
        .product(name: "MacHIDCapture", package: "mac-hid"),
        .product(name: "MacAudioHost", package: "mac-audio"),
        .product(name: "MacPowerHost", package: "mac-power")]),
    .executableTarget(name: "tessera-mac-test", dependencies: ["TesseraHostKit"]),
    .testTarget(name: "TesseraHostKitTests", dependencies: ["TesseraHostKit",
        .product(name: "MacAudioHost", package: "mac-audio")])
], swiftLanguageModes: [.v5])
