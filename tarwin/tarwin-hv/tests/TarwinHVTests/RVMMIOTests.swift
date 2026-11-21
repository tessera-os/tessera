import Testing

@testable import TarwinHV

private func op(
  _ code: UInt64, _ cause: UInt64 = 21, _ htval: UInt64 = 0x100,
  _ stval: UInt64 = 0x8400, _ at: UInt64 = 0x8000,
  _ fetch: (UInt64) -> UInt16? = { _ in nil }
) -> RVMMIOAccess? {
  RVMMIOAccess(
    cause: cause, hstatus: 0xc0, stval: stval, htval: htval, htinst: code, pc: at,
    vsatp: 0, readGPR: { _ in 0x400 }, fetch: fetch,
    registered: { $0 >= 0x400 && $0 < 0x408 && $1 <= 0x408 - $0 })
}

@Test func rvMMIOUsesGPAAndHonorsXLENSignAndZeroRegister() throws {
  let signed = try #require(op(0x183, 21, 0x100, 0xa503))  // LB x3
  #expect(signed.address == 0x403 && signed.nextPC == 0x8004)
  var bank = [UInt64](repeating: 0, count: 32)
  signed.completeLoad(0x8180) { bank[Int($0)] = $1 }
  #expect(bank[3] == UInt64.max - 127)
  let unsigned = try #require(op(0x6183))  // LWU x3
  unsigned.completeLoad(.max) { bank[Int($0)] = $1 }
  #expect(bank[3] == 0xffff_ffff)
  let zero = try #require(op(3))
  var visits = 0
  zero.completeLoad(1) { _, _ in visits += 1 }
  let store = try #require(op(0x23, 23))
  #expect(
    store.exit { _ in
      visits += 1
      return 99
    }.data == 0)
  #expect(visits == 0)
}

@Test func rvMMIOFetchesOnlyRequiredHalvesAndAcceptsTransformedCompressed() throws {
  var fetched = [UInt64]()
  let c = try #require(
    op(0, 21, 0x100, 0x400, 0x8002) {
      fetched.append($0)
      return 0x4482
    })  // C.LWSP x9
  #expect(c.register == 9 && c.nextPC == 0x8004 && fetched == [0x8002])
  let transformed = try #require(op(0x2481))  // expanded C.LW -> LW x9
  #expect(transformed.width == 4 && transformed.nextPC == 0x8002 && transformed.register == 9)
  fetched = []
  let two = try #require(
    op(0, 23, 0x100, 0x400, 0x8ffe) {
      fetched.append($0)
      return $0 == 0x8ffe ? 0xa023 : 0x0090  // SW x9,0(x1)
    })
  #expect(fetched == [0x8ffe, 0x9000] && two.register == 9)
  #expect(two.exit { _ in .max }.data == 0xffff_ffff)
}

@Test func rvMMIORejectsImplicitAndUnsupportedAccessWithoutDeviceEffects() {
  // htinst == 0: don't confuse an implicit VS page walk, or the second
  // half of a misaligned access, with an explicit scalar access at stval.
  func fallback(_ vsatp: UInt64, _ base: UInt64) -> RVMMIOAccess? {
    RVMMIOAccess(
      cause: 21, hstatus: 0xc0, stval: 0x400, htval: 0x100, htinst: 0, pc: 0x8000,
      vsatp: vsatp, readGPR: { _ in base }, fetch: { _ in 0x4000 }, registered: { _, _ in true })
  }
  #expect(fallback(1 << 63, 0x400) == nil && fallback(0, 0x3ff) == nil && fallback(0, 0x400) != nil)
  for code: UInt64 in [0x2000, 0x3000, 0x302f, 0x7003, 0x1_0000_0003, 0x8003] {
    #expect(op(code) == nil)
  }
  #expect(op(0x23) == nil)
  #expect(op(0x3003, 21, 0x100, 0x402) == nil)
  #expect(op(3, 21, 0x102) == nil)
  #expect(op(3, 21, 1 << 48) == nil)
  #expect(op(0, 21, 0x100, 0x400, 0x8000) { $0 == 0x8000 ? 3 : nil } == nil)
  #expect(op(0, 21, 0x100, 0x400, 0x8000) { _ in 0x4002 } == nil)  // C.LWSP x0 reserved
  #expect(op(3, 21, 0x100, 0x400, .max - 1) == nil)
  #expect(
    RVMMIOAccess(
      cause: 21, hstatus: 0x80, stval: 0x400, htval: 0x100, htinst: 3, pc: 0,
      vsatp: 0, readGPR: { _ in 0 }, fetch: { _ in nil }, registered: { _, _ in true }) == nil)
}
