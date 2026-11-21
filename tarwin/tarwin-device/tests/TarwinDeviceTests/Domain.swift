import XCTest

@testable import TarwinDevice

final class DomainTests: XCTestCase {

  func testFailedMapBlocksAddressReuseUntilIotlbAndAtcCompletion() {
    withUnsafeTemporaryAllocation(of: DomainEntry.self, capacity: 4) { storage in
      storage.initialize(repeating: .vacant)
      defer { storage.deinitialize() }
      let handle = PinnedIoHandle(koid: 14, kind: .iommuDomain, rights: 512)
      let memory = PinnedIoHandle(koid: 15, kind: .memory, rights: 4)
      var slot = DeviceSlotState(group: 12)
      XCTAssertTrue(slot.assign(true, 9, { g, e in return true }))
      var d = SlotDomain(
        group: 12, koid: 14, epoch: 1, aperture: DeviceRange(base: 0x1000_0000, length: 4096),
        page: 4096, storage: storage)
      let read = DmaSpan(offset: 0, bytes: 4096, access: .deviceRead)
      let write = DmaSpan(offset: 0, bytes: 4096, access: .deviceWrite)
      var pins: UInt64 = 0
      let pin: (UInt64, DmaSpan) -> UInt64 = { id, s in
        pins += 1
        return pins
      }
      let partial: (UInt64, UInt64, UInt64, DmaSpan) -> Bool = { domain, iova, p, s in return false
      }
      let mapped: (UInt64, UInt64, UInt64, DmaSpan) -> Bool = { domain, iova, p, s in
        return iova == 0x1000_0000
      }
      XCTAssertTrue(
        d.create(handle, memory, slot, 9, 4096, write, 0, pin, partial) == MapDma.refused)
      XCTAssertTrue(pins == 0)
      XCTAssertTrue(
        d.create(handle, memory, slot, 9, 4096, read, 0, pin, partial) == MapDma.quarantined(1))
      let ok: (UInt64, UInt64, UInt64) -> Bool = { domain, addr, n in return true }
      let no: (UInt64, UInt64, UInt64) -> Bool = { domain, addr, n in return false }
      var released: UInt64 = 0
      let unpin: (UInt64) -> Void = { id in released = id }
      XCTAssertTrue(!d.retire(1, ok, ok, no, unpin))
      XCTAssertTrue(d.create(handle, memory, slot, 9, 4096, read, 0, pin, mapped) == MapDma.retry)
      XCTAssertTrue(pins == 1 && released == 0)
      XCTAssertTrue(d.retire(1, no, no, ok, unpin))
      XCTAssertTrue(released == 1)
      switch d.create(handle, memory, slot, 9, 4096, read, 0, pin, mapped) {
      case .mapped(let m): XCTAssertTrue(m.address == 0x1000_0000 && m.id == 2 && pins == 2)
      default: XCTAssertTrue(false)
      }
    }
  }
}
