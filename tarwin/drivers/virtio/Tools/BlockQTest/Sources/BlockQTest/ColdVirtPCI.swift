import Foundation
import TarwinDevice

private struct Registers: ColdVirtRegisters {
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
}
