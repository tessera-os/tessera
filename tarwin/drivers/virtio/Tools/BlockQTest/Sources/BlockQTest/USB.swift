import Foundation
import TarwinBlockWire
import TarwinDevice
import USBMassStorage

/// CPU side of three synthetic, pinned grants. Controller pointers are
/// non-identity IOVAs; translating one back here does not authorize device DMA.
private final class USBAperture: UHCITransport {
  let q: QTest, bias: UInt64, frames: [UInt64]
  init(_ q: QTest, _ bias: UInt64, _ frames: [UInt64]) {
    self.q = q
    self.bias = bias
    self.frames = frames
  }
  func read16(_ offset: UInt16) throws -> UInt16 {
    let s = q.send("inw \(0xc000 + Int(offset))")
    guard s.hasPrefix("0x"), let n = UInt16(s.dropFirst(2), radix: 16) else {
      throw Failure("USB register read")
    }
    return n
  }
  func write16(_ offset: UInt16, _ value: UInt16) throws {
    _ = q.send("outw \(0xc000 + Int(offset)) \(value)")
    if let e = q.error { throw e }
  }
  func write32(_ offset: UInt16, _ value: UInt32) throws {
    _ = q.send("outl \(0xc000 + Int(offset)) \(value)")
    if let e = q.error { throw e }
  }
  func delay(milliseconds: Int) throws {
    _ = q.send("clock_step \(milliseconds * 1_000_000)")
    if let e = q.error { throw e }
  }
  private func physical(_ address: UInt32, _ n: Int) throws -> UInt64 {
    guard UInt64(address) >= bias, (1...4096).contains(n) else { throw Failure("USB pin") }
    let at = UInt64(address) - bias
    guard frames.contains(at & ~4095), (at & 4095) + UInt64(n) <= 4096 else {
      throw Failure("USB range")
    }
    return at
  }
  func loadDMA(_ address: UInt32, count: Int) throws -> [UInt8] {
    let p = try physical(address, count)
    guard let data = Data(base64Encoded: q.send("b64read \(p) \(count)")), data.count == count
    else { throw Failure("USB DMA read") }
    return Array(data)
  }
  func loadStatus(_ address: UInt32) throws -> UInt32 {
    let s = UInt32(q.read("l", try physical(address, 4)))
    if let e = q.error { throw e }
    return s
  }
  func storeDMA(_ address: UInt32, _ bytes: [UInt8]) throws {
    let at = try physical(address, bytes.count)
    _ = q.send("b64write \(at) \(bytes.count) \(Data(bytes).base64EncodedString())")
    if let e = q.error { throw e }
  }
}

private struct NoUSBGrants: USBBlockGrants {
  func readable(_ address: UInt64, count: Int) -> UnsafeRawBufferPointer? { nil }
  func writable(_ address: UInt64, count: Int) -> UnsafeMutableRawBufferPointer? { nil }
}

func testUSBStorage(binary: String, disk: URL) throws {
  var expected = try Data(contentsOf: disk)
  let qcow = disk.appendingPathExtension("qcow2")
  let raw = disk.appendingPathExtension("verify")
  defer {
    try? FileManager.default.removeItem(at: qcow)
    try? FileManager.default.removeItem(at: raw)
  }
  @discardableResult func img(_ args: [String]) throws -> Data {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: binary).deletingLastPathComponent()
      .appendingPathComponent("qemu-img")
    p.arguments = args
    p.standardOutput = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure("qemu-img " + args[0]) }
    return out
  }
  struct Extent: Decodable {
    let start, length: Int
    let data: Bool
  }
  func holes() throws -> [Range<Int>] {
    let map = try JSONDecoder().decode(
      [Extent].self, from: img(["map", "--output=json", "-f", "qcow2", qcow.path]))
    return map.filter { !$0.data }.map { $0.start..<($0.start + $0.length) }
  }
  try img(["convert", "-f", "raw", "-O", "qcow2", "-o", "cluster_size=4096", disk.path, qcow.path])
  guard try holes().isEmpty else { throw Failure("USB fixture not fully allocated") }
  let target = (24 * 512)..<(32 * 512)
  let frames: [UInt64] = [0x120000, 0x121000, 0x122000]
  let q = try QTest(
    binary: binary, machine: .x64, disk: qcow, translated: true, neighbors: false, storage: .usb,
    unmap: true, qcow2: true)
  do {
    let matches = q.pciNodes.filter { $0.device.identity == 0x7020_8086 }
    guard matches.count == 1, case .pci(0, let rid) = matches[0].device.location
    else { throw Failure("Missing UHCI controller") }
    let dma = try TranslatedDisk(
      q, requester: rid, queues: [(frames[0], .deviceRead), (frames[1], .both), (frames[2], .both)])
    func select(_ offset: UInt32) {
      _ = q.send("outl 0xcf8 \(0x8000_0000 | UInt32(rid) << 8 | offset)")
    }
    select(0x20)
    _ = q.send("outl 0xcfc 0xffffffff")
    try q.require(q.send("inl 0xcfc") == "0xffffffe1", "Not a 32-byte UHCI I/O BAR")
    _ = q.send("outl 0xcfc 0xc001")
    select(4)
    _ = q.send("outw 0xcfc 5")
    let io = USBAperture(q, dma.bias, frames)
    let a = frames.map { UInt32(dma.bias + $0) }
    let host = UHCIStorageBus(
      io: io, pages: UHCIPages(frames: a[0], schedule: a[1], bounce: a[2])!, rootPort: 0)!
    let intf = try host.configure()
    var dev = try USBDisk(pipes: host, interface: intf, lun: 0)
    try q.require(
      dev.blockBytes == 512 && dev.blocks == UInt64(expected.count / 512), "USB disk geometry")
    let data = (0..<(3 * 512)).map { UInt8(truncatingIfNeeded: 231 + $0 * 53) }
    try dev.write(lba: 5, blocks: 3, data: data, fua: dev.forceUnitAccess)
    try dev.flush()
    expected.replaceSubrange(5 * 512..<8 * 512, with: data)
    let actual = try dev.read(lba: 4, blocks: 5)
    try q.require(actual.elementsEqual(expected[(4 * 512)..<(9 * 512)]), "translated USB readback")
    var service = try USBBlockService(consume dev, epoch: 1)
    let request = BlockRequest(
      id: 7, epoch: 1, lba: 24, blocks: 8, queue: 0, op: .discard, qos: .utility, payload: .init())!
    let response = service.execute(request.record(), grants: NoUSBGrants())
    try q.require(response?.id == 7 && response?.status == .ok, "USB UNMAP completion")
    let flush = BlockRequest(
      id: 8, epoch: 1, lba: 0, blocks: 0, queue: 0, op: .flush, qos: .utility, payload: .init())!
    try q.require(
      service.execute(flush.record(), grants: NoUSBGrants())?.status == .ok, "USB post-UNMAP flush")
    try host.stop()
    select(4)
    _ = q.send("outw 0xcfc 1")
    for p in frames { try q.require(dma.retireData(page: p, frame: p), "USB pin drain") }
    try dma.close(q)
    try q.require(dma.retired == frames.count, "all UHCI pins drained")
  } catch {
    q.close()
    throw error
  }
  q.close()
  guard try holes() == [target] else { throw Failure("USB deallocation extent differed") }
  try img(["convert", "-f", "qcow2", "-O", "raw", qcow.path, raw.path])
  expected.resetBytes(in: target)  // Unbacked qcow2 hole; not a device read-zero promise.
  guard try Data(contentsOf: raw) == expected else { throw Failure("USB backing image differed") }
}
