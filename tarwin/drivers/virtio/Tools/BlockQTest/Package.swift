// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "BlockQTest", platforms: [.macOS(.v26)],
  dependencies: [
    .package(path: "../../../nvme"),
    .package(path: "../../../usb-storage"),
    .package(path: "../../../ufs"),
    .package(path: "../../../../trfs"), .package(path: "../../../../tarwin-net"),
    .package(path: "../../../../kcore"), .package(path: "../../../../tarwin-boot"),
    .package(path: "../../../../tarwin-loader"), .package(path: "../../../../tarwin-loader/w0"),
    .package(path: "../.."),
    .package(path: "../../../../tarwin-block"),
    .package(path: "../../../../tarwin-device"), .package(path: "../../../../tarwin-ipc"),
    .package(path: "../../../../tarwin-object"), .package(path: "../../../../tarwin-syscall"),
  ],
  targets: [
    .executableTarget(
      name: "BlockQTest",
      dependencies: [
        .product(name: "NVMeDriver", package: "nvme"),
        .product(name: "USBMassStorage", package: "usb-storage"),
        .product(name: "UFSDriver", package: "ufs"),
        .product(name: "TRFS", package: "trfs"),
        .product(name: "TarwinLoader", package: "tarwin-loader"),
        .product(name: "TarwinW0Verify", package: "w0"),
        .product(name: "VirtioNetService", package: "virtio"),
        .product(name: "TarwinNet", package: "tarwin-net"),
        .product(name: "TarwinObject", package: "tarwin-object"),
        .product(name: "TarwinSyscall", package: "tarwin-syscall"),
        .product(name: "TarwinABI", package: "tarwin-syscall"),
        .product(name: "KCore", package: "kcore"), .product(name: "TarwinBoot", package: "tarwin-boot"),
        .product(name: "TarwinBlock", package: "tarwin-block"),
        .product(name: "TarwinIoCompletion", package: "tarwin-device"),
        .product(name: "TarwinDevice", package: "tarwin-device"),
        .product(name: "TarwinIPC", package: "tarwin-ipc"),
        .product(name: "VirtioBlockService", package: "virtio"),
        .product(name: "VirtioGuest", package: "virtio"),
      ])
  ])
