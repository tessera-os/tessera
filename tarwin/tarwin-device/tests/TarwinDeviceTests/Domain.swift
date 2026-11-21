import XCTest

@testable import TarwinDevice

final class DomainTests: XCTestCase {

  func testRevokingSlotOwnsAllDrainsIncludingUnpublishedMaps() {
    withUnsafeTemporaryAllocation(of: DomainEntry.self, capacity: 3) { storage in
      storage.initialize(repeating: .vacant)
      defer { storage.deinitialize() }
      var slot = DeviceSlotState(group: 7)
      XCTAssertTrue(slot.assign(true, 81) { _, _ in true })
      let active = slot
      var domain = SlotDomain(
        group: 7, koid: 90, epoch: active.epoch,
        aperture: .init(base: 4096, length: 16384), page: 4096, storage: storage)
      var pins = 0
      func map(_ word: UInt64, _ publish: Bool) -> MapDma {
        domain.create(
          .init(koid: 90, kind: .iommuDomain, rights: 512),
          .init(koid: 91, kind: .memory, rights: 4), active, 81, 4096,
          .init(offset: 0, bytes: 4096, access: .deviceRead), word,
          { _, _ in
            pins += 1
            return UInt64(pins)
          }, { _, _, _, _ in publish })
      }
      XCTAssertEqual(map(0, true), .mapped(.init(id: 1, address: 4096)))
      domain.bindLastMapping(1, buffer: 110)
      XCTAssertEqual(map(1, false), .quarantined(2))
      XCTAssertEqual(map(2, true), .mapped(.init(id: 3, address: 12288)))
      domain.bindLastMapping(3, buffer: 112)
      var stopped = false
      var allowAtc = false
      var resets = 0
      var detached: [UInt64] = []
      var flushed: [UInt64] = []
      var unpinned: [UInt64] = []
      var mappings: [UInt64] = []
      var buffers: [UInt64?] = []
      func drain(_ group: UInt64, _ epoch: UInt64) -> Bool {
        domain.revokeAll(
          group: group, epoch: epoch, requestersStoppedAndDrained: stopped,
          detach: { _, a, _ in
            detached.append(a)
            return true
          },
          invalidate: { _, a, _ in
            flushed.append(a)
            return true
          },
          drainAtcs: { _, a, _ in a != 8192 || allowAtc },
          unpin: { unpinned.append($0) },
          retired: {
            mappings.append($0)
            buffers.append($1)
          })
      }
      func revoke() -> Bool {
        slot.revoke(
          false, { true }, { true }, { drain(7, active.epoch) },
          {
            resets += 1
            return true
          })
      }
      XCTAssertFalse(drain(8, active.epoch))
      XCTAssertFalse(drain(7, active.epoch + 1))
      XCTAssertFalse(domain.revoking)
      XCTAssertFalse(revoke())
      XCTAssertTrue(domain.revoking)
      XCTAssertEqual(slot.phase, .draining)
      XCTAssertTrue(detached.isEmpty)
      XCTAssertEqual(map(3, true), .refused)
      XCTAssertEqual(pins, 3)
      let nope: (UInt64, UInt64, UInt64) -> Bool = { _, _, _ in
        XCTFail()
        return false
      }
      XCTAssertFalse(domain.retire(2, nope, nope, nope) { _ in XCTFail() })
      stopped = true
      XCTAssertFalse(revoke())
      XCTAssertEqual(resets, 0)
      XCTAssertEqual(domain.count, 2)
      XCTAssertEqual(unpinned, [3])
      XCTAssertEqual(buffers, [112])
      XCTAssertFalse(
        slot.assign(true, 82) { _, _ in
          XCTFail()
          return false
        })
      allowAtc = true
      XCTAssertTrue(revoke())
      XCTAssertTrue(drain(7, active.epoch))
      XCTAssertEqual(domain.count, 0)
      XCTAssertEqual(resets, 1)
      XCTAssertEqual(detached, [12288, 8192, 4096])
      XCTAssertEqual(flushed, detached)
      XCTAssertEqual(mappings, [3, 2, 1])
      XCTAssertEqual(unpinned, mappings)
      XCTAssertEqual(buffers, [112, nil, 110])
      XCTAssertTrue(slot.assign(true, 82) { _, _ in true })
      XCTAssertGreaterThan(slot.epoch, active.epoch)
      XCTAssertEqual(map(3, true), .refused)
    }
  }

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
