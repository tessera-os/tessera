#if TARBOOT_TEST_COLD_FENCE
@_extern(c, "tarwin_mmio_read32") private func load32(_ p: UnsafeRawPointer) -> UInt32

func reportFenceState() -> Bool {
  func register(_ address: UInt64) -> Bool {
    let value = load32(UnsafeRawPointer(bitPattern: UInt(address))!), hex: StaticString = "0123456789abcdef"
    guard uartByte(32) else { return false }
    for i in 0..<8 where !uartByte(hex.utf8Start[Int(value >> ((7 - i) * 4) & 15)]) { return false }
    return true
  }
  for fn in 0..<3 {
    let p = 0x40_1000_0000 + UInt64(fn * 0x8000)
    guard emit("TARWIN-COLD-PCI"), register(p), register(p + 4) else { return false }
    for i in 0..<6 where !register(p + 0x10 + UInt64(i * 4)) { return false }
    guard emit("\r\n") else { return false }
  }
  let s: UInt64 = 0x0905_0000
  return emit("TARWIN-COLD-GICR") && register(0x080a_0000) && register(0x080a_0008)
    && emit("\r\nTARWIN-COLD-SMMU") && register(s + 0x20) && register(s + 0x24)
    && register(s + 0x44) && register(s + 0x50) && register(s + 0x54)
    && register(s + 0x60) && register(s + 0x64) && register(s + 0x98) && register(s + 0x9c) && emit("\r\n")
}
#endif
