// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "TarwinBootstrap", platforms: [.macOS(.v26)],
  products: [
    .library(name: "TarwinBootstrap", targets: ["TarwinBootstrap"]),
    .library(name: "TarbootPreflight", targets: ["TarbootPreflight"]),
    .library(name: "TarwinW1Bootstrap", targets: ["TarwinW1Bootstrap"]),
  ],
  dependencies: [
    .package(path: "../../../tarwin/tarwin-sched"),
    .package(path: "../../../tarwin/tarwin-time"),
    .package(path: "../../../tarwin/kcore"),
    .package(path: "../../../tarwin/tarboot"),
    .package(path: "../../../tarwin/tarwin-loader"),
    .package(path: "../../../tarwin/tarwin-boot"),
    .package(path: "../../../tarwin/tarwin-loader/w0"),
    .package(path: "../../../tarwin/tarwin-mm"),
    .package(path: "../../../tarwin/tarwin-arch-aarch64"),
    .package(path: "../../../tarwin/tarwin-syscall"),
    .package(path: "../../../tarwin/tarwin-security/random"),
    .package(path: "../../../tarwin/tarwin-syscall/first-entry"),
    .package(path: "../../../tarwin/tarwin-syscall/channel-calls"),
    .package(path: "../../../tarwin/tarwin-object"),
    .package(path: "../../../tarwin/tarwin-ipc"),
  ],
  targets: [
    .target(
      name: "TarwinBootstrap",
      dependencies: [
        .product(name: "TarwinSched", package: "tarwin-sched"),
        .product(name: "TarwinTime", package: "tarwin-time"),
      ]),
    .testTarget(name: "TarwinBootstrapTests", dependencies: ["TarwinBootstrap"]),
    .target(
      name: "TarbootPreflight",
      dependencies: [
        .product(name: "KCore", package: "kcore"),
        .product(name: "Tarboot", package: "tarboot"),
        .product(name: "TarwinLoader", package: "tarwin-loader"),
      ]),
    .testTarget(name: "TarbootPreflightTests", dependencies: ["TarbootPreflight"]),
    .target(
      name: "TarwinW1Bootstrap", dependencies: [
        .product(name: "TarwinChannelCalls", package: "channel-calls"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "TarwinArmBootstrap", package: "first-entry"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinIPCChannels", package: "tarwin-ipc"),
        .product(name: "TarwinKernelRandom", package: "random"),
        .product(name: "TarwinProcessKeys", package: "random"),
        .product(name: "TarwinRandomCore", package: "random"),
        .product(name: "TarwinArchAarch64", package: "tarwin-arch-aarch64"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinBoot", package: "tarwin-boot"),
        .product(name: "TarwinW0Verify", package: "w0"),
        .product(name: "TarwinLoader", package: "tarwin-loader"),
        .product(name: "TarwinMM", package: "tarwin-mm"),
      ]),
    .testTarget(name: "TarwinW1BootstrapTests", dependencies: [
      .product(name: "TarwinKernelRandom", package: "random"),
      .product(name: "TarwinProcessKeys", package: "random"),
      .product(name: "TarwinIPCChannels", package: "tarwin-ipc"),
      .product(name: "TarwinObject", package: "tarwin-object"),
      .product(name: "TarwinW0Verify", package: "w0"),
      "TarwinW1Bootstrap", .product(name: "TarwinLoader", package: "tarwin-loader"),
      .product(name: "TarwinArchAarch64", package: "tarwin-arch-aarch64"),
      .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      .product(name: "TarwinABI", package: "tarwin-syscall"),
      .product(name: "Tarboot", package: "tarboot"), .product(name: "KCore", package: "kcore"),
      .product(name: "TarwinMM", package: "tarwin-mm"),
    ]),
  ])
