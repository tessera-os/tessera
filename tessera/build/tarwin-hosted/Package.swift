// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["TARWIN_SOURCE_ROOT"] ?? "../../../tarwin"
let package = Package(
  name: "tarwin-hosted", platforms: [.macOS("26.0")],
  products: [.library(name: "TarwindKernel", targets: ["TarwindKernel"])],
  dependencies: [
    .package(path: "\(root)/tarwin-arch-hosted"), .package(path: "\(root)/tarwin-time"),
    .package(path: "\(root)/tarwin-sched"), .package(path: "\(root)/tarwin-object"),
    .package(path: "\(root)/tarwin-sync"), .package(path: "\(root)/tarwin-ipc"),
    .package(path: "\(root)/tarwin-syscall"), .package(path: "\(root)/tarwin-syscall/providers"),
    .package(path: "\(root)/tarwin-syscall/channel-calls"),
    .package(path: "\(root)/tarwin-mm"), .package(path: "\(root)/tarwin-loader"),
  ],
  targets: [
    .target(name: "TarwindKernel", dependencies: [
      .product(name: "TarwinArchHosted", package: "tarwin-arch-hosted"),
      .product(name: "TarwinTime", package: "tarwin-time"),
      .product(name: "TarwinSched", package: "tarwin-sched"),
      .product(name: "TarwinObject", package: "tarwin-object"),
      .product(name: "TarwinSync", package: "tarwin-sync"),
      .product(name: "TarwinIPCChannels", package: "tarwin-ipc"),
      .product(name: "TarwinSyscall", package: "tarwin-syscall"),
      .product(name: "TarwinABI", package: "tarwin-syscall"),
      .product(name: "TarwinObjectCalls", package: "providers"),
      .product(name: "TarwinSyncCalls", package: "providers"),
      .product(name: "TarwinKernelCalls", package: "providers"),
      .product(name: "TarwinChannelCalls", package: "channel-calls"),
      .product(name: "TarwinMM", package: "tarwin-mm"),
      .product(name: "TarwinLoader", package: "tarwin-loader"),
    ]),
    .testTarget(name: "TarwindKernelTests", dependencies: ["TarwindKernel"]),
  ], swiftLanguageModes: [.v6])
