import TarwinArchX64
import TarwinMM

@_extern(c, "mca_cpuid") private func cpuid(_ leaf: UInt32, _ regs: UnsafeMutablePointer<UInt32>)
@_extern(c, "mca_cap") private func cap() -> UInt64
@_extern(c, "mca_status") private func status() -> UInt64
@_extern(c, "mca_addr") private func address() -> UInt64
@_extern(c, "mca_misc") private func misc() -> UInt64
@_extern(c, "mca_clear") private func clear()
@_extern(c, "mca_note") private func put(_ byte: UInt8)

private func text(_ s: StaticString) {
  for i in 0..<s.utf8CodeUnitCount { put(s.utf8Start[i]) }
}

private func intelMCAWidth() -> UInt8? {
  var registers = InlineArray<4, UInt32>(repeating: 0)
  return withUnsafeMutableBytes(of: &registers) {
    let row = $0.bindMemory(to: UInt32.self), p = row.baseAddress!
    cpuid(0, p)
    guard row[0] >= 1, row[1] == 0x756e6547, row[3] == 0x49656e69, row[2] == 0x6c65746e
    else { return nil }
    cpuid(1, p)
    guard row[3] & 0x40a0 == 0x40a0 else { return nil }  // MSR, MCE, MCA
    cpuid(0x8000_0000, p)
    guard row[0] >= 0x8000_0008 else { return nil }
    cpuid(0x8000_0008, p)
    let bits = UInt8(truncatingIfNeeded: row[0])
    return (32...52).contains(bits) ? bits : nil
  }
}

// One CPU, exclusive bank 4, IRQs masked after EFI exit. The host supplies
// exactly one corrected record per handshake. Never enable #MC or clear
// an unknown, overflowing, or ambiguously addressed report.
func checkMCA(_ pages: inout MonitoredPageArena) -> Bool {
  guard let bits = intelMCAWidth(), cap() & 255 > 4, status() == 0 else { return false }
  let owned = pages.take(order: 0)
  guard owned.ok else { return false }
  for i in 0..<2 {
    text(i == 0 ? "MCA0 " : "MCA1 ")
    for k in (0..<16).reversed() {
      let n = UInt8((owned.address >> (4 * k)) & 15)
      put(n < 10 ? 48 + n : 87 + n)
    }
    put(10)
    var s: UInt64 = 0
    for _ in 0..<200_000_000 {
      s = status()
      if s >> 63 != 0 { break }
    }
    guard s & 0x8c00_0000_0000_0000 == 0x8c00_0000_0000_0000 else { return false }
    let a = address(), m = misc()
    guard status() == s else { return false }
    let page = x64CorrectedMemoryPage(status: s, address: a, misc: m, physicalBits: bits)
    #if TARBOOT_TEST_MCA_WIDE
      guard i == 0, m == 0x8d, page == nil, status() == s, pages.correctedCount(at: owned.address) == 0
      else { return false }
      text("MCA-WIDE-RETAINED\n")
      return true  // Retain the page and error record until guest shutdown.
    #else
      guard page == owned.address,
        pages.corrected(at: a) == (i == 0 ? .counted : .evacuate) else { return false }
      clear()
      guard status() == 0 else { return false }
    #endif
  }
  guard pages.correctedCount(at: owned.address) == 2, pages.give(address: owned.address, order: 0)
  else { return false }
  let next = pages.take(order: 0)
  guard next.ok, next.address != owned.address, pages.give(address: next.address, order: 0)
  else { return false }
  text("MCA-CORRECTED-FRAME-RETIRED\n")
  return true
}
