import TarwinDevice
import XCTest

private struct Drains: GroupTeardown {
  var result = false, events: [String] = []
  mutating func maskInterrupts(group: UInt64) -> Bool {
    events.append("mask-\(group)")
    return true
  }
  mutating func revokeMaps(group: UInt64) -> Bool {
    events.append("maps-\(group)")
    return true
  }
  mutating func retireDma(group: UInt64) -> Bool {
    events.append("dma-\(group)")
    return result
  }
  mutating func reset(group: UInt64) -> Bool {
    events.append("reset-\(group)")
    return true
  }
}
private func dev(_ id: UInt16, _ group: UInt64?, parent: UInt16? = nil, mmio: UInt64? = nil)
  -> HardwareDevice
{
  HardwareDevice(
    location: .pci(segment: 0, requester: id),
    parent: parent.map { .pci(segment: 0, requester: $0) },
    stable: StableDeviceID(high: 1, low: UInt64(id)), identity: UInt64(id), deviceClass: 0,
    group: group,
    mmio: mmio.map {
      [MmioAperture(range: DeviceRange(base: $0, length: 4096), frameBuffer: false)]
    } ?? [], wiredInterrupts: 1, powerStates: 1, wakeCapable: false)
}
final class RegistryTests: XCTestCase {
  func testBridgeReplacementQuarantinesAllAliasesAndDescendantsBeforeRegrant() {
    var r = HardwareRegistry(limit: 8)!
    var p = Drains()
    let root = dev(1, nil)
    let a = dev(2, 7, parent: 1)
    let b = dev(3, 7)
    let snapshot = [root, a, b, dev(4, 9, parent: 3)]
    XCTAssertTrue(r.stage(snapshot, reason: .orderly))
    XCTAssertTrue(r.commit(&p))
    XCTAssertEqual(r.changes(deviceRoot: false, after: nil), .denied)
    XCTAssertNil(r.assign(deviceRoot: true, node: 1, process: 10, isolate: { _, _ in true }))
    XCTAssertNil(r.assign(deviceRoot: false, node: 2, process: 10, isolate: { _, _ in true }))
    let lease = r.assign(
      deviceRoot: true, node: 2, process: 10, isolate: { g, e in g == 7 && e == 1 })!
    XCTAssertTrue(r.permits(lease, process: 10, node: 3))
    XCTAssertFalse(r.permits(lease, process: 10, node: 4))
    XCTAssertNil(r.assign(deviceRoot: true, node: 3, process: 11, isolate: { _, _ in true }))
    _ = r.assign(deviceRoot: true, node: 4, process: 12, isolate: { _, _ in true })
    XCTAssertTrue(r.stage(snapshot, replaced: [root.location], reason: .surprise))
    XCTAssertFalse(r.permits(lease, process: 10, node: 2))
    XCTAssertFalse(r.commit(&p))
    XCTAssertEqual(p.events, ["mask-9", "maps-9", "dma-9"])
    XCTAssertEqual(r.changes(deviceRoot: true, after: 1), .transitioning)
    r.freeze()
    p.result = true
    XCTAssertTrue(r.commit(&p))
    XCTAssertEqual(r.changes(deviceRoot: true, after: nil), .transitioning)
    XCTAssertTrue(r.stage(snapshot, reason: .orderly))
    XCTAssertTrue(r.commit(&p))
    guard case .changes(2, let changes) = r.changes(deviceRoot: true, after: 1),
      case .snapshot(2, let current) = r.changes(deviceRoot: true, after: 0)
    else { return XCTFail() }
    XCTAssertEqual(Array(changes.prefix(4)), [4, 3, 2, 1].map { .removed(UInt64($0), .surprise) })
    XCTAssertEqual(current.map(\.id), [5, 6, 7, 8])
    XCTAssertEqual(current.map(\.parentID), [0, 5, 0, 7])
    let new = r.assign(deviceRoot: true, node: 6, process: 10, isolate: { _, _ in true })!
    XCTAssertGreaterThan(new.epoch, lease.epoch)
    XCTAssertFalse(r.permits(lease, process: 10, node: 6))
    XCTAssertTrue(r.permits(new, process: 10, node: 7))
    XCTAssertEqual(
      p.events,
      ["mask-9", "maps-9", "dma-9", "dma-9", "reset-9", "mask-7", "maps-7", "dma-7", "reset-7"])
  }
  func testInvalidSnapshotsFreezeAdmissionAndAddingAnAliasRevokesTheGroup() {
    var r = HardwareRegistry(limit: 4)!
    var p = Drains()
    let a = dev(1, 5, mmio: 0x1000)
    let b = dev(2, 5, mmio: 0x2000)
    XCTAssertTrue(r.stage([a], reason: .orderly))
    XCTAssertTrue(r.commit(&p))
    let old = r.assign(deviceRoot: true, node: 1, process: 3, isolate: { _, _ in true })!
    XCTAssertFalse(r.stage([a, dev(2, 6, mmio: 0x1800)], reason: .surprise))
    XCTAssertFalse(r.permits(old, process: 3, node: 1))
    XCTAssertFalse(r.stage([a, a], reason: .orderly))
    XCTAssertFalse(r.stage([dev(2, 5, parent: 9)], reason: .orderly))
    XCTAssertTrue(r.stage([a, b], reason: .orderly))
    p.result = true
    XCTAssertTrue(r.commit(&p))
    XCTAssertFalse(r.permits(old, process: 3, node: 2))
    let next = r.assign(deviceRoot: true, node: 2, process: 3, isolate: { _, _ in true })!
    XCTAssertGreaterThan(next.epoch, old.epoch)
    XCTAssertTrue(r.permits(next, process: 3, node: 3))
    XCTAssertTrue(r.revoke(next, deviceRoot: true, provider: &p))
    XCTAssertFalse(r.permits(next, process: 3, node: 2))
    let third = r.assign(deviceRoot: true, node: 3, process: 3, isolate: { _, _ in true })!
    XCTAssertGreaterThan(third.epoch, next.epoch)
    XCTAssertFalse(r.revoke(next, deviceRoot: true, provider: &p))
  }
  func testGroupReappearanceKeepsEpochMonotonicAcrossAnEmptyRegistry() {
    var registry = HardwareRegistry(limit: 1)!
    let device = dev(1, 9)
    var teardown = Drains(result: true)
    var lastEpoch: UInt64 = 0
    for _ in 0..<3 {
      XCTAssertTrue(registry.stage([device], reason: .orderly))
      XCTAssertTrue(registry.commit(&teardown))
      guard case .snapshot(_, let nodes) = registry.changes(deviceRoot: true, after: nil),
        let node = nodes.first
      else { return XCTFail() }
      let lease = registry.assign(deviceRoot: true, node: node.id, process: 4) { group, epoch in
        group == 9 && epoch > lastEpoch
      }
      guard let lease else { return XCTFail("Isolation provider did not receive a fresh epoch") }
      XCTAssertGreaterThan(lease.epoch, lastEpoch)
      lastEpoch = lease.epoch
      XCTAssertTrue(registry.stage([], reason: .surprise))
      XCTAssertTrue(registry.commit(&teardown))
      XCTAssertFalse(registry.permits(lease, process: 4, node: node.id))
    }
  }
}
