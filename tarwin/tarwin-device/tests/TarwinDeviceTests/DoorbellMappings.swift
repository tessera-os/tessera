import TarwinObject
import XCTest

import TarwinDevice

private struct RangeTeardown: GroupTeardown, ~Copyable {
  var binding: RegisteredDoorbellRange?
  var ack = false, drains = 0
  mutating func reset(group: UInt64) -> Bool { true }
  mutating func maskInterrupts(group: UInt64) -> Bool { true }
  mutating func retireDma(group: UInt64) -> Bool {
    drains += 1
    return true
  }
  mutating func revokeMaps(group: UInt64) -> Bool {
    let acknowledged = ack
    return binding?.revoke(
      group: group, unmapAndSync: { _, _ in acknowledged },
      retire: { _ in XCTFail() }) ?? true
  }
}

final class DoorbellMappingsTests: XCTestCase {
  func testRegistryFreezesLiveGrantsAndDrainsBeforePublishingReplacedGpu() {
    let ids = KoidSource()
    let objects = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 2)
    for (i, k) in [TarwinKind.mmioRange, TarwinKind.process].enumerated() {
      (objects + i).initialize(
        to: ObjectHeader(source: ids, ownerJob: 3, kind: k, maximumRights: 1023)!)
    }
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 2)
    var caller = HandleTable(storage: cells, salt: 7)!
    let slab = UnsafeMutableBufferPointer<DoorbellPage>.allocate(capacity: 1)
    slab.initialize(repeating: DoorbellPage(offset: 4096))
    defer {
      caller.drain { _ in XCTFail() }
      XCTAssertEqual(objects.pointee.release(), .destroy)
      XCTAssertEqual((objects + 1).pointee.release(), .destroy)
      objects.deinitialize(count: 2)
      objects.deallocate()
      cells.deinitialize()
      cells.deallocate()
      slab.deinitialize()
      slab.deallocate()
    }
    guard case .installed(let range) = caller.install(objects, rights: 528),
      case .installed(let client) = caller.install(objects + 1, rights: 512)
    else { return XCTFail() }
    var registry = HardwareRegistry(limit: 1)!
    var teardown = RangeTeardown()
    let gpu = HardwareDevice(
      location: .pci(segment: 0, requester: 8), parent: nil,
      stable: .init(high: 1, low: 1), identity: 1, deviceClass: 0x030000, group: 3,
      mmio: [.init(range: .init(base: 0x10000, length: 8192), frameBuffer: false)],
      wiredInterrupts: 1, powerStates: 1, wakeCapable: false)
    XCTAssertTrue(registry.stage([gpu], reason: .orderly))
    XCTAssertTrue(registry.commit(&teardown))
    let lease = registry.assign(deviceRoot: true, node: 1, process: 71, isolate: { _, _ in true })!
    func bind(_ node: UInt64, _ aperture: Int) -> RegisteredDoorbellRange? {
      registry.bindDoorbellRange(
        objects, lease: lease, node: node, apertureIndex: aperture,
        pageBytes: 4096, designated: slab)
    }
    XCTAssertTrue(bind(2, 0) == nil)
    XCTAssertTrue(bind(1, 1) == nil)
    slab[0] = DoorbellPage(offset: 8192)
    XCTAssertTrue(bind(1, 0) == nil)
    slab[0] = DoorbellPage(offset: 4096)
    teardown.binding = bind(1, 0)
    var installed = 0
    func grant() -> DoorbellReply? {
      teardown.binding?.grant(
        rangeName: range, processName: client, offset: 4096, registry: registry,
        callerProcess: 71, caller: caller.reader,
        installWriteOnlyUcNx: { _, _ in
          installed += 1
          return .installed
        },
        retire: { _ in XCTFail() })
    }
    XCTAssertEqual(grant(), .mapped)
    registry.freeze()
    XCTAssertEqual(grant(), .unavailable)
    XCTAssertTrue(registry.stage([gpu], replaced: [gpu.location], reason: .surprise))
    XCTAssertFalse(registry.commit(&teardown))
    XCTAssertEqual(teardown.drains, 0)
    teardown.ack = true
    XCTAssertTrue(registry.commit(&teardown))
    XCTAssertEqual(teardown.drains, 1)
    XCTAssertNotNil(
      registry.assign(deviceRoot: true, node: 2, process: 71, isolate: { _, _ in true }))
    XCTAssertEqual(grant(), .unavailable)
    XCTAssertEqual(installed, 1)
  }
  func testSlotCannotBeReusedUntilLastClientMappingIsRevoked() {
    let ids = KoidSource()
    func object(_ kind: UInt32) -> UnsafeMutablePointer<ObjectHeader> {
      let p = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
      p.initialize(to: ObjectHeader(source: ids, ownerJob: 1, kind: kind, maximumRights: 1023)!)
      return p
    }
    let r = object(TarwinKind.mmioRange)
    let p = object(TarwinKind.process)
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 4)
    var table = HandleTable(storage: cells, salt: 42)!
    defer {
      table.drain { _ in XCTFail() }
      XCTAssertEqual(r.pointee.release(), .destroy)
      for h in [r, p] {
        h.deinitialize(count: 1)
        h.deallocate()
      }
      cells.deinitialize()
      cells.deallocate()
    }
    func name(_ mutation: HandleMutation) -> UInt64 {
      guard case .installed(let n) = mutation else {
        XCTFail()
        return 0
      }
      return n
    }
    let range = name(table.install(r, rights: 528))
    let target = name(table.install(p, rights: 512))
    let weak = name(table.install(r, rights: 16))
    let weakTarget = name(table.install(p, rights: 4))
    let slab = UnsafeMutableBufferPointer<DoorbellPage>.allocate(capacity: 2)
    slab.initialize(repeating: DoorbellPage(offset: 0))
    defer {
      slab.deinitialize()
      slab.deallocate()
    }
    slab[1] = DoorbellPage(offset: 8192)
    var slot = DeviceSlotState(group: 3)
    XCTAssertTrue(slot.assign(true, 19, { _, _ in true }))
    func valid(_ base: UInt64, _ bytes: UInt64, _ pageBytes: UInt64) -> Bool {
      if DoorbellMappings(
        range: r, slot: slot, aperture: .init(base: base, length: bytes),
        pageBytes: pageBytes, pages: slab) != nil
      {
        return true
      }
      return false
    }
    XCTAssertFalse(valid(1, 12288, 4096))
    XCTAssertFalse(valid(0, 12287, 4096))
    XCTAssertFalse(valid(0, 12288, 0))
    slab[1] = DoorbellPage(offset: 0)
    XCTAssertFalse(valid(0, 12288, 4096))
    slab[1] = DoorbellPage(offset: 8192)
    var ledger = DoorbellMappings(
      range: r, slot: slot, aperture: DeviceRange(base: 0x10000, length: 12288),
      pageBytes: 4096, pages: slab)!
    var retired = 0
    var installs = 0
    func retire(_ h: UnsafePointer<ObjectHeader>) {
      XCTAssertEqual(h, UnsafePointer(p))
      retired += 1
    }
    func grant(
      _ rng: UInt64, _ process: UInt64, _ off: UInt64, _ result: DoorbellInstall,
      _ driver: UInt64 = 19, _ currentSlot: DeviceSlotState? = nil
    ) -> DoorbellReply {
      ledger.grant(
        rangeName: rng, processName: process, offset: off, slot: currentSlot ?? slot,
        callerProcess: driver,
        caller: table.reader,
        installWriteOnlyUcNx: { m, h in
          installs += 1
          XCTAssertEqual(m.process, p.pointee.koid)
          XCTAssertEqual(h, UnsafePointer(p))
          XCTAssertEqual(m.bytes, 4096)
          XCTAssertEqual(m.physical, 0x10000 + off)
          XCTAssertEqual(m.range, r.pointee.koid)
          return result
        }, retire: retire)
    }
    XCTAssertEqual(grant(weak, target, 0, .installed), .denied)
    XCTAssertEqual(grant(range, weakTarget, 0, .installed), .denied)
    XCTAssertEqual(grant(range, target, 4096, .installed), .notDesignated)
    var obsolete = slot
    XCTAssertTrue(obsolete.revoke(false, { true }, { true }, { true }, { true }))
    XCTAssertTrue(obsolete.assign(true, 19, { _, _ in true }))
    XCTAssertEqual(grant(range, target, 0, .installed, 19, obsolete), .unavailable)
    XCTAssertEqual(grant(range, target, 1, .installed), .notDesignated)
    XCTAssertEqual(grant(range, target, 0, .installed, 20), .denied)
    XCTAssertEqual(installs, 0)
    XCTAssertEqual(grant(range, target, 0, .unchanged), .mappingFailed)
    XCTAssertEqual(grant(range, target, 0, .installed), .mapped)
    XCTAssertEqual(grant(range, target, 0, .installed), .busy)
    XCTAssertEqual(grant(range, target, 8192, .needsRevocation), .mappingFailed)
    XCTAssertEqual(grant(range, target, 0, .installed), .unavailable)
    XCTAssertTrue(table.close(target, retire: retire))
    XCTAssertTrue(table.close(weakTarget, retire: retire))
    XCTAssertEqual(p.pointee.release(), .stillLive)
    var synced = false
    var seen: [UInt64] = []
    func unmap() -> Bool {
      ledger.revoke(
        group: 3, epoch: 1,
        unmapAndSync: { m, _ in
          seen.append(m.offset)
          return m.offset == 0 || synced
        }, retire: retire)
    }
    XCTAssertFalse(
      slot.revoke(
        false, { true }, unmap,
        {
          XCTFail()
          return false
        },
        {
          XCTFail()
          return false
        }))
    XCTAssertEqual(slot.phase, .unmapping)
    XCTAssertFalse(slot.assign(true, 37, { _, _ in true }))
    XCTAssertEqual(retired, 0)
    synced = true
    XCTAssertTrue(
      slot.revoke(
        false,
        {
          XCTFail()
          return false
        }, unmap, { true }, { true }))
    XCTAssertEqual(seen, [0, 8192, 8192])
    XCTAssertEqual(retired, 1)
    XCTAssertTrue(slot.assign(true, 37, { _, _ in true }))
    XCTAssertEqual(slot.epoch, 2)
  }
}
