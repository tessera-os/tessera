import CryptoKit
import Darwin
import Foundation
import TarwinBoot
import Testing

private struct WireError: Error {}
private struct Banks: MemoryBankSink {
  var memory: [Range<UInt64>] = []
  var reserved: [Range<UInt64>] = []
  mutating func bank(_ base: UInt64, length: UInt64) -> Bool {
    memory.append(base..<(base + length))
    return true
  }
  mutating func reserve(_ base: UInt64, length: UInt64) -> Bool {
    reserved.append(base..<(base + length))
    return true
  }
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  return url
}

private func command(_ args: [String]) -> Process {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = args
  return p
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["QEMU_TREES"] == "1"))
func qemuFirmwareMemoryBanks() throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = dir.appendingPathComponent("firmware.dtb")
  for (isa, machine, base): (String, String, UInt64) in [
    ("aarch64", "virt,gic-version=3,virtualization=on,iommu=smmuv3", 0x4000_0000),
    ("riscv64", "virt", 0x8000_0000),
  ] {
    let p = command([
      "qemu-system-" + isa, "-machine", machine + ",dumpdtb=" + path.path,
      "-m", "16G", "-smp", "4", "-nographic", "-nodefaults",
    ])
    try p.run()
    p.waitUntilExit()
    try #require(p.terminationStatus == 0)
    var sink = Banks()
    let bytes = try HostBytes(Array(Data(contentsOf: path)))
    #expect(stageMemoryBanks(bytes, sink: &sink))
    #expect(sink.memory == [base..<(base + (16 << 30))])
    var ids = [FirmwareProcessor](repeating: .empty, count: 4)
    let enumerated = ids.withUnsafeMutableBufferPointer {
      treeProcessors(bytes, family: isa == "aarch64" ? .arm64 : .rv64, into: $0)
    }
    #expect(enumerated == 4 && Set(ids.map(\.hardwareID)) == Set([0, 1, 2, 3]))
  }
  for (child, valid) in [
    ("carve@40010000 {reg=<0x40010000 0x10000>; no-map;};", true),
    ("carve {size=<0x10000>;};", false),
    ("carve@40010000 {reg=<0x40010000>;};", false),
  ] {
    let dts = """
      /dts-v1/; /memreserve/ 0x40000100 0x10;
      / { #address-cells=<1>; #size-cells=<1>;
      memory@40000000 { device_type="memory"; reg=<0x40000000 0x100000>; };
      memory@60000000 { device_type="memory"; reg=<0x60000000 0x1000>; status="disabled"; };
      reserved-memory { #address-cells=<1>; #size-cells=<1>; ranges;
      \(child) }; };
      """
    let source = dir.appendingPathComponent("fixture.dts")
    try Data(dts.utf8).write(to: source)
    let p = command(["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", path.path, source.path])
    try p.run()
    p.waitUntilExit()
    try #require(p.terminationStatus == 0)
    let bytes = try HostBytes(Array(Data(contentsOf: path)))
    var sink = Banks()
    #expect(stageMemoryBanks(bytes, sink: &sink) == valid)
    if valid {
      #expect(sink.memory == [0x4000_0000..<0x4010_0000])
      #expect(sink.reserved == [0x4001_0000..<0x4002_0000, 0x4000_0100..<0x4000_0110])
    }
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["QEMU_TREES"] == "1"))
func treeCPUsRejectAmbiguousIDsAndIncompleteRecords() throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  let source = dir.appendingPathComponent("cpu.dts")
  let blob = dir.appendingPathComponent("cpu.dtb")
  for (node, valid) in [
    ("cpu@1 { device_type=\"cpu\"; reg=<1 0>; status=\"disabled\"; };", true),
    ("cpu@1 { device_type=\"cpu\"; reg=<0 7>; };", false),
    ("cpu@1 { device_type=\"cpu\"; reg=<1>; };", false),
    ("cpu@1 { reg=<0 1>; };", false),
    ("cpu@1 { device_type=\"cpu\"; reg=<0 1>; status=\"okay\",\"disabled\"; };", false),
    ("rogue@1 { device_type=\"cpu\"; reg=<0 1>; };", false),
  ] {
    let dts = """
      /dts-v1/;
      / { cpus { #address-cells=<2>; #size-cells=<0>;
        cpu-map { core0 { reg=<0 9>; }; };
        cpu@7 { reg=<0 7>; device_type="cpu"; intc { reg=<0 99>; }; };
        \(node) }; };
      """
    try Data(dts.utf8).write(to: source)
    let p = command(["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", blob.path, source.path])
    try p.run()
    p.waitUntilExit()
    try #require(p.terminationStatus == 0)
    let tree = HostBytes(Array(try Data(contentsOf: blob)))
    var ids = [FirmwareProcessor](repeating: .empty, count: 4)
    let count = ids.withUnsafeMutableBufferPointer { treeProcessors(tree, family: .rv64, into: $0) }
    if valid { #expect(count == 1 && ids[0].hardwareID == 7) } else { #expect(count == nil) }
  }
}

@Test func truncatedAndUnbalancedTrees() {
  var fdt = HostBytes(count: 72)
  for (at, value): (Int, UInt8) in [
    (0, 0xd0), (1, 0x0d), (2, 0xfe), (3, 0xed), (7, 72), (11, 56), (15, 72), (19, 40),
    (23, 17), (27, 16), (39, 16), (59, 1), (67, 2), (71, 9),
  ] { fdt.bytes[at] = value }
  var sink = Banks()
  #expect(stageMemoryBanks(fdt, sink: &sink))
  fdt.bytes[67] = 4
  #expect(!stageMemoryBanks(fdt, sink: &sink))
  fdt.bytes[67] = 2
  fdt.bytes[55] = 7
  #expect(!stageMemoryBanks(fdt, sink: &sink))
  fdt.bytes[55] = 0
  fdt.bytes.removeLast()
  #expect(!stageMemoryBanks(fdt, sink: &sink))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWTPM_REPLAY"] == "1"))
func softwareTPMReplay() throws {
  let dir = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }
  var fds: [Int32] = [-1, -1]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw WireError() }
  let client = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
  let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
  // Foundation passes the socket as stdin; swtpm requires a descriptor above 2.
  let p = command([
    "sh", "-c", "exec 3<&0; exec \"$@\"", "swtpm-test",
    "swtpm", "socket", "--tpm2", "--tpmstate", "dir=" + dir.path,
    "--fd", "3", "--terminate", "--flags", "not-need-init,startup-clear",
  ])
  p.standardInput = child
  try p.run()
  try child.close()
  defer {
    try? client.close()
    if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }
    p.waitUntilExit()
  }
  func read(_ size: Int) throws -> Data {
    var bytes = Data()
    while bytes.count < size {
      var pollFD = pollfd(fd: client.fileDescriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&pollFD, 1, 5000) == 1,
        let part = try client.read(upToCount: size - bytes.count), !part.isEmpty
      else { throw WireError() }
      bytes.append(part)
    }
    return bytes
  }
  func send(_ packet: [UInt8]) throws -> [UInt8] {
    try client.write(contentsOf: Data(packet))
    let header = try read(10)
    let size = header[2..<6].reduce(0) { ($0 << 8) | Int($1) }
    guard (10...4096).contains(size), header[6..<10].allSatisfy({ $0 == 0 }) else {
      throw WireError()
    }
    return try Array(header + read(size - 10))
  }
  func readPCR() throws -> [UInt8] {
    let reply = try send([128, 1, 0, 0, 0, 20, 0, 0, 1, 126, 0, 0, 0, 1, 0, 11, 3, 0, 1, 0])
    guard reply.count == 62,
      Array(reply[14..<30]) == [0, 0, 0, 1, 0, 11, 3, 0, 1, 0, 0, 0, 0, 1, 0, 32]
    else { throw WireError() }
    return Array(reply.suffix(32))
  }
  let before = try readPCR()
  let digest = HostBytes(Array(0..<32))
  var port = HostBytes(count: 65)
  var event = HostBytes(count: 53)
  try #require(encodePcrExtend(8, digest: digest, command: &port) == 65)
  try #require(
    stagePcrEvent(8, digest: digest, event: HostBytes(Array("abc".utf8)), log: &event, pos: 0) == 53
  )
  let response = try send(port.bytes)
  try #require(pcrExtendSucceeded(HostBytes(response)))
  let replay = SHA256.hash(data: Data(before + event.bytes[14..<46]))
  #expect(try readPCR() == Array(replay))
}
