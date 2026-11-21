import Testing
@testable import Tarboot
@testable import TarwinBoot

#if arch(arm64)
  // Called only under this test's scoped firmware-table borrow.
  nonisolated(unsafe) private var instance: UnsafeRawPointer?

  @Test func bootHartRequiresMatchingProtocolInventoryAndFinalHSMStates() throws {
    let locate: LocateProtocol = { guid, key, result in
      precondition(key == nil && Array(UnsafeRawBufferPointer(start: guid, count: 16)) == [
        0xec, 0x5f, 0xd1, 0xcc, 0x73, 0x6f, 0xec, 0x4e, 0x83, 0x95, 0x3e, 0x69, 0xe4, 0xb9, 0x40, 0xbf])
      result.pointee = instance
      return 0
    }
    let good: FirmwareBootHart.GetID = { table, out in
      precondition(table == instance)
      out.pointee = 0x102
      return 0
    }
    let failed: FirmwareBootHart.GetID = { _, out in out.pointee = 0x102; return 1 }
    let unwritten: FirmwareBootHart.GetID = { _, _ in 0 }
    var table = (UInt64(0), UInt64(0))
    #expect(FirmwareBootHart(locate) == nil)
    try withUnsafeMutableBytes(of: &table) { raw in
      instance = UnsafeRawPointer(raw.baseAddress!)
      defer { instance = nil }
      raw.storeBytes(of: good, toByteOffset: 8, as: FirmwareBootHart.GetID.self)
      #expect(FirmwareBootHart(locate) == nil)
      raw.storeBytes(of: UInt64(0x10000), as: UInt64.self)
      for method in [nil, failed, unwritten] as [FirmwareBootHart.GetID?] {
        raw.storeBytes(of: method, toByteOffset: 8, as: FirmwareBootHart.GetID?.self)
        #expect(FirmwareBootHart(locate) == nil)
      }
      raw.storeBytes(of: good, toByteOffset: 8, as: FirmwareBootHart.GetID.self)
      let hart = try #require(FirmwareBootHart(locate))
      func check(_ ids: [UInt64], _ states: [UInt64: UInt64]) -> UInt64? {
        ids.map { FirmwareProcessor(hardwareID: $0, acpiUID: nil) }.withUnsafeBufferPointer {
          hart.verifiedID(in: $0, hsmStatus: { states[$0] })
        }
      }
      let states: [UInt64: UInt64] = [7: 1, 0x102: 0, 0: 1]
      #expect(check([7, 0x102, 0], states) == 0x102)
      for ids: [UInt64] in [[], [7, 0], [7, 7, 0x102], [7, 0x102, 0x102], [0x102, .max], [0x102, 9]] {
        #expect(check(ids, states) == nil)
      }
      for other: UInt64 in [0, 2, 3, 4, 5, 6, .max] {
        #expect(check([7, 0x102], [7: other, 0x102: 0]) == nil)
      }
      #expect(check([7, 0x102], [7: 1, 0x102: 1]) == nil)
    }
  }
#endif
