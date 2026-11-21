import Foundation
import TarwinDevice
import VirtioGuest

private struct Registers: VirtBootFenceBus {
  let q: QTest
  func read32(_ physical: UInt64) -> UInt32? {
    let value = UInt32(truncatingIfNeeded: q.read("l", physical))
    return q.error == nil ? value : nil
  }
  func write32(_ physical: UInt64, _ value: UInt32) -> Bool {
    q.write("l", physical, value)
    return q.error == nil
  }
  func fwConfigWord(_ selector: UInt16) -> UInt32? {
    q.write("w", 0x0902_0008, selector.bigEndian)
    var word: UInt32 = 0
    for i in 0..<4 { word |= UInt32(q.read("b", 0x0902_0000)) << (8 * i) }
    return q.error == nil ? word : nil
  }
  func read8(_ p: UInt64) -> UInt8? {
    let value = UInt8(truncatingIfNeeded: q.read("b", p))
    return q.error == nil ? value : nil
  }
  func write8(_ p: UInt64, _ value: UInt8) -> Bool {
    q.write("b", p, value)
    return q.error == nil
  }
  func write16(_ p: UInt64, _ value: UInt16) -> Bool {
    q.write("w", p, value)
    return q.error == nil
  }
  func read64(_ p: UInt64) -> UInt64? {
    let value = q.read("q", p)
    return q.error == nil ? value : nil
  }
  func write64(_ p: UInt64, _ value: UInt64) -> Bool {
    q.write("q", p, value)
    return q.error == nil
  }
  // QTest acknowledges each store before the next command.
  func publishStores() {}
}

func testColdVirtPCI(binary: String, disk: URL) throws {
  for (fwDma, platformRng, expected) in [
    (true, false, ColdVirtPCIResult.unsupportedPlatform),
    (false, true, .unsupportedPlatform), (false, false, .pciAbortAcknowledged),
  ] {
    let q = try QTest(coldVirt: binary, disk: disk, fwDma: fwDma, platformRng: platformRng)
    defer { q.close() }
    var registers = Registers(q: q)
    guard registers.read32(0x0905_0044) == 0x1000,
      requestColdVirtPCIAbort(registers: &registers) == expected,
      registers.read32(0x0905_0044) == (expected == .pciAbortAcknowledged ? 0x10_1000 : 0x1000),
      q.error == nil
    else {
      throw Failure(
        "Unexpected cold PCI state (fw_cfg DMA: \(fwDma); platform RNG: \(platformRng))")
    }
  }
  let trace = disk.deletingPathExtension().appendingPathExtension("trace")
  defer { try? FileManager.default.removeItem(at: trace) }
  do {
    let q = try QTest(coldVirt: binary, disk: disk, fwDma: false, platformRng: false, trace: trace)
    defer { q.close() }
    var registers = Registers(q: q)
    let disk: UInt64 = 0x40_1000_8000
    let rng: UInt64 = 0x40_1001_0000
    func activate(_ i: Int) throws {
      let fn = i == 0 ? disk : rng
      let bar = 0x2000_0000 + UInt64(i) * 65536
      let base = 0x4100_0000 + UInt64(i) * 0x40_0000
      q.write("l", fn + 0x20, UInt32(bar))
      q.write("w", fn + 4, 6)
      func width(_ w: UInt32) -> String { w == 4 ? "l" : w == 2 ? "w" : "b" }
      func rd(_ off: UInt32, _ w: UInt32) -> UInt32 { UInt32(q.read(width(w), bar + UInt64(off))) }
      func wr(_ off: UInt32, _ w: UInt32, _ v: UInt32) { q.write(width(w), bar + UInt64(off), v) }
      let end = ContinuousClock.now + .seconds(2)
      guard case .negotiated = negotiatePci(0, rd, wr, { .now >= end }) else {
        throw Failure("Could not negotiate fixed firmware PCI endpoint")
      }
      // These queues reside in the synthetic archive and staging extents.
      wr(22, 2, 0)
      wr(24, 2, 8)
      for (r, page): (UInt32, UInt32) in [(32, 0), (40, 4096), (48, 8192)] {
        wr(r, 4, UInt32(base) + page)
        wr(r + 4, 4, 0)
      }
      wr(28, 2, 1)
      wr(20, 1, 15)
    }
    for i in 0..<2 { try activate(i) }
    let ranges = [
      DeviceRange(base: 0x4100_0000, length: 1 << 20),
      DeviceRange(base: 0x4140_0000, length: 12288),
    ]
    let snapshots = ranges.map { q.send("read \($0.base) 12288") }
    let result = ranges.withUnsafeBufferPointer {
      denyVirtBootDMA(table: 0x4200_0000, commands: 0x4200_1000, protected: $0, bus: &registers)
    }
    try q.require(result == .streamsDenied, "Boot PCI fence: \(result)")
    try q.require(
      q.read("w", disk + 4) & 4 == 0 && q.read("w", rng + 4) & 4 == 0
        && q.read("l", 0x0905_0024) == 9 && q.read("l", 0x0905_009c) == 3,
      "Requester/stream or command drain missing")
    for i in 0..<512 {
      try q.require(
        q.read("q", 0x4200_0000 + UInt64(8 * i)) == (i % 8 == 0 ? 1 : 0),
        "Unexpected non-abort stream entry")
    }
    // Test harness only: give the same endpoints another queue activation
    // without changing the SMMU. A parked device alone cannot pass this test.
    for i in 0..<2 { try activate(i) }
    try q.require(q.read("l", 0x0905_0024) == 9, "Stream table lost ownership")
    try q.require(
      snapshots == ranges.map { q.send("read \($0.base) 12288") },
      "Reactivation modified a protected queue")
  }
  let events = try String(contentsOf: trace, encoding: .utf8)
  for (sid, iova) in [("8", "41002000"), ("10", "41401002")] {
    guard events.contains("sid=0x" + sid + " bypass (smmu disabled) iova:0x" + iova),
      events.contains("sid=0x" + sid + " abort on iova:0x" + iova)
    else { throw Failure("Missing baseline or denied queue DMA from SID 0x" + sid) }
  }
}
