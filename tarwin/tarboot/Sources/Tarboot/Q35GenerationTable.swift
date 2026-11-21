import KCore

// Recognize the closed AML emitted by QEMU's vmgenid_build_acpi, not an AML
// interpreter or a scan for a plausible address next to a device name. Only
// the firmware relocation of Name(VGIA, DWord(...)) varies within this body.
func q35GenerationBase<S: ByteSource>(_ s: S) -> UInt64? {
  guard s.byteCount() >= 202, little(s, at: 0, bytes: 4) == 0x5444_5353,
    little(s, at: 4, bytes: 4) == 202, s.byteAt(8) == 1,
    little(s, at: 16, bytes: 8) == 0x0044_494e_4547_4d56 else { return nil }
  var sum: UInt8 = 0
  for i: UInt64 in 0..<202 { sum &+= s.byteAt(i) }
  guard sum == 0 else { return nil }
  var offset: UInt64 = 36
  func aml(_ length: Int, _ pattern: UInt64) -> Bool {
    guard offset + UInt64(length) <= 202 else { return false }
    var word: UInt64 = 0
    for _ in 0..<length {
      word = (word << 8) | UInt64(s.byteAt(offset))
      offset += 1
    }
    return word == pattern
  }
  func name(_ text: StaticString) -> Bool {
    for i in 0..<text.utf8CodeUnitCount {
      guard offset < 202, s.byteAt(offset) == text.utf8Start[i] else { return false }
      offset += 1
    }
    return true
  }
  guard aml(1, 0x08), name("VGIA"), aml(1, 0x0c) else { return nil }
  let page = little(s, at: offset, bytes: 4)
  offset += 4
  guard page != 0, page & 4095 == 0,
    aml(4, 0x1041_085c), name("_SB_"), aml(4, 0x5b82_4807), name("VGEN"),
    aml(1, 0x08), name("_HID"), aml(1, 0x0d), name("QEMUVGID"), aml(1, 0x00),
    aml(1, 0x08), name("_CID"), aml(1, 0x0d), name("VM_Gen_Counter"), aml(1, 0x00),
    aml(1, 0x08), name("_DDN"), aml(1, 0x0d), name("VM_Gen_Counter"), aml(1, 0x00),
    // _STA: present iff VGIA is nonzero.
    aml(2, 0x1417), name("_STA"), aml(8, 0x0070_0a0f_60a0_0a93),
    name("VGIA"), aml(6, 0x0070_0060_a460),
    // ADDR: return the two-DWord package { VGIA + 40, 0 }.
    aml(2, 0x1420), name("ADDR"), aml(8, 0x0070_1202_0260_7072), name("VGIA"),
    aml(8, 0x0a28_0088_6000_0070), aml(7, 0x0088_6001_00a4_60),
    aml(4, 0x1419_5c2e), name("_GPE_E05"), aml(4, 0x0086_5c2e),
    name("_SB_VGEN"), aml(2, 0x0a80), offset == 202 else { return nil }
  return page
}
