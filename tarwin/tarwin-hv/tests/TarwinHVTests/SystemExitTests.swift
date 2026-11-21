import Testing

@testable import TarwinHV

@Test func armSysregDecodeRequiresDelegationAndHonorsXZR() {
  let base: UInt64 = (0x18 << 26) | (1 << 25) | (3 << 20) | (4 << 1)
  var reads = 0
  func decode(_ esr: UInt64, _ pending: Bool = false) -> ExitRecord? {
    armSystemExit(
      esr: esr, interruptPending: pending, allow: { id, _ in id == 0xc020 },
      readGPR: {
        reads += 1
        return $0 + 1
      })
  }
  #expect(decode(base | 9 << 5)?.data == 10)
  #expect(decode(base | 31 << 5)?.data == 0 && reads == 1)
  #expect(decode(base | 7 << 5 | 1)?.registerIndex == 7 && reads == 1)
  #expect(decode(base ^ 1 << 17) == nil)
  #expect(decode(3 << 25)?.reason == .wait)
  #expect(decode(3 << 25, true) == nil && decode(3 << 25 | 1) == nil)
}

@Test func rvVirtualCSRReadsDoNotDelegateRMWOrWaitWhilePending() {
  func decode(_ inst: UInt64, _ status: UInt64 = 0x180, _ pending: Bool = false) -> ExitRecord? {
    rvSystemExit(
      cause: 22, hstatus: status, pc: 0x8002, stval: inst, interruptPending: pending,
      fetch: { $0 == 0x8002 ? 0x2873 : 0x1800 }, allowRead: { $0 == 0x180 })
  }
  #expect(decode(0)?.registerIndex == 16)
  #expect(decode(0x1800_3873)?.address == 0x180)
  #expect(decode(0x1800_9873) == nil && decode(0x1800_1873) == nil)
  #expect(decode(0x1800_2873, 0x80) == nil && decode(0x1810_2873) == nil)
  #expect(decode(0x1050_0073)?.reason == .wait && decode(0x1050_0073, 0x180, true) == nil)
}
