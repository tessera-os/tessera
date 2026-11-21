import TarwinArchAarch64
import Testing

@available(macOS 26, *)
@Test func firstEntryChecksPrivateMappingsAndStartsWithoutStaleRegisters() throws {
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 8 * 16384, alignment: 16)
  defer { bytes.deallocate() }
  guard var tables = ArmUserTranslation(backing: bytes, physical: 0x80_000) else {
    Issue.record("missing root"); return
  }
  let page: UInt64 = 16384, code: UInt64 = 1 << 32, top = (UInt64(1) << 43) + 8 * page
  let rx = code..<code+20, stack = top-page..<top, tcb = top+page+64
  func state(_ h: UInt64, _ pc: UInt64, _ s: Range<UInt64>, _ tp: UInt64) -> ArmInitialState? {
    ArmInitialState(tables: tables, entry: pc, imageRX: rx, bootstrapChannel: h, stack: s, tcb: tp)
  }
  func map(_ va: UInt64, _ pa: UInt64, _ w: Bool, _ x: Bool) -> Bool {
    tables.insert(virtual: va, physical: pa, write: w, execute: x)
  }
  #expect(map(code, 0x40000, false, true))
  #expect(map(top-page, 0x44000, true, false))
  #expect(state(7, code+4, stack, tcb) == nil)
  #expect(map(top+page, 0x48000, true, false))
  let s = try #require(state(7, code+4, stack, tcb))
  #expect(s.elr == code+4 && s.sp == top && s.tpidr == tcb && s.spsr == 0)
  #expect(s.fpcr == 0 && s.fpsr == 0 && s.gpr[0] == 7)
  for i in 1..<31 { #expect(s.gpr[i] == 0) }
  for i in 0..<64 { #expect(s.vectorHalves[i] == 0) }
  #expect(state(0, code+4, stack, tcb) == nil)
  #expect(state(7, code+3, stack, tcb) == nil)
  #expect(state(7, code+20, stack, tcb) == nil)
  #expect(state(7, code+4, stack, tcb+8) == nil)
  #expect(state(7, code+4, stack, top-page) == nil)
  #expect(state(7, code+4, top-page..<top+page, tcb) == nil)
  #expect(map(top-5*page, 0x4c000, false, false))
  #expect(state(7, code+4, stack, tcb) == nil)
}
