import TarwinDevice
import XCTest

private struct Tables: VtdTableMemory {
  var next: UInt64 = 0x1000, values: [UInt64: UInt64] = [:]
  mutating func allocateTable() -> UInt64? {
    defer { next += 4096 }
    return next
  }
  func word(_ p: UInt64) -> UInt64? { values[p] ?? 0 }
  mutating func publish(_ p: UInt64, _ v: UInt64) -> Bool {
    values[p] = v
    return true
  }
}
private struct Registers: VtdRegisters {
  var cap: UInt64 = (3 << 54) | (38 << 16) | (1 << 9), status: UInt32 = 0, root: UInt64 = 0
  var busy = false, refused = false, context: UInt64 = 0, tlb: UInt64 = 0
  var writes: [UInt32] = []
  func read32(_ offset: UInt32) -> UInt32 { status }
  func read64(_ offset: UInt32) -> UInt64 {
    switch offset {
    case 8: cap
    case 16: 0xf00
    case 0x20: root
    case 0x28: context
    case 0xf8: tlb
    default: .max
    }
  }
  mutating func write32(_ offset: UInt32, _ value: UInt32) {
    writes.append(offset)
    status |= value
  }
  mutating func write64(_ offset: UInt32, _ value: UInt64) {
    writes.append(offset)
    switch offset {
    case 0x20: root = value
    case 0x28: context = refused ? 0 : 1 << 59
    case 0xf8:
      tlb = busy ? 1 << 63 : (refused ? 0 : 1 << 57)
      XCTAssertEqual(value, (1 << 63) | (1 << 60) | (3 << 48))
    default: XCTFail()
    }
  }
  func expired() -> Bool { true }
}
final class VtdTests: XCTestCase {
  func testUnitRejectsUnsupportedAndActiveState() {
    var r = Registers()
    let u = VtdLegacyUnit(registerBytes: 4096, registers: &r)!
    XCTAssertEqual(u.maxDomain, 15)
    XCTAssertNil(VtdLegacyUnit(registerBytes: 0xf8, registers: &r))
    XCTAssertFalse(
      u.start(root: 4096, allRequestersBlocked: true, atsDisabled: false, registers: &r))
    XCTAssertFalse(
      u.start(root: 4096, allRequestersBlocked: false, atsDisabled: true, registers: &r))
    XCTAssertTrue(r.writes.isEmpty)
    XCTAssertTrue(u.start(root: 4096, allRequestersBlocked: true, atsDisabled: true, registers: &r))
    XCTAssertEqual(r.writes, [0x20, 0x18, 0x28, 0xf8, 0x18])
    XCTAssertFalse(
      u.start(root: 8192, allRequestersBlocked: true, atsDisabled: true, registers: &r))
    r.status = 1 << 26
    XCTAssertFalse(u.flushTranslations(registers: &r))
    r.cap &= ~(1 << 54)
    XCTAssertNil(VtdLegacyUnit(registerBytes: 4096, registers: &r))
  }
  func testNoRegrantAfterFailedIotlbDrain() {
    var m = Tables()
    var r = Registers()
    let d = VtdDomain(id: 1, physicalBits: 39, memory: &m)!
    let u = VtdLegacyUnit(registerBytes: 4096, registers: &r)!
    let i: UInt64 = 0x1245_6000
    let p: UInt64 = 0x40000
    XCTAssertFalse(d.mapPage(iova: i + 1, frame: p, access: .both, memory: &m))
    XCTAssertFalse(d.mapPage(iova: 1 << 39, frame: p, access: .both, memory: &m))
    XCTAssertFalse(d.mapPage(iova: i, frame: 1 << 39, access: .both, memory: &m))
    XCTAssertTrue(d.mapPage(iova: i, frame: p, access: .deviceRead, memory: &m))
    XCTAssertTrue(m.values.values.contains(p | 1))
    XCTAssertFalse(d.mapPage(iova: i, frame: p, access: .both, memory: &m))
    XCTAssertFalse(d.detach(iova: i, frame: p + 4096, memory: &m))
    XCTAssertTrue(d.detach(iova: i, frame: p, memory: &m))
    r.busy = true
    XCTAssertFalse(d.drainDetached(iova: i, frame: p, unit: u, memory: &m, registers: &r))
    XCTAssertFalse(d.mapPage(iova: i, frame: p + 4096, access: .deviceWrite, memory: &m))
    r.busy = false
    r.tlb = 0
    r.refused = true
    XCTAssertFalse(d.drainDetached(iova: i, frame: p, unit: u, memory: &m, registers: &r))
    r.refused = false
    XCTAssertTrue(d.drainDetached(iova: i, frame: p, unit: u, memory: &m, registers: &r))
    XCTAssertTrue(d.mapPage(iova: i, frame: p + 4096, access: .deviceWrite, memory: &m))
    XCTAssertTrue(m.values.values.contains((p + 4096) | 2))
  }
  func testRequesterCannotBeReassignedUntilContextAndIotlbAreRetired() {
    var m = Tables()
    var r = Registers()
    let root = m.allocateTable()!
    let u = VtdLegacyUnit(registerBytes: 4096, registers: &r)!
    let a = VtdDomain(id: 1, physicalBits: 39, memory: &m)!
    let b = VtdDomain(id: 2, physicalBits: 39, memory: &m)!
    var token = a.bind(rootTable: root, requester: 0x342, unit: u, memory: &m)!
    func vacant(_ m: inout Tables) -> Bool {
      b.bind(rootTable: root, requester: 0x342, unit: u, memory: &m) != nil
    }
    XCTAssertFalse(vacant(&m))
    XCTAssertFalse(
      token.retire(requesterStoppedAndDrained: false, unit: u, memory: &m, registers: &r))
    r.busy = true
    XCTAssertFalse(
      token.retire(requesterStoppedAndDrained: true, unit: u, memory: &m, registers: &r))
    XCTAssertFalse(vacant(&m))
    XCTAssertEqual(r.writes, [0x28, 0xf8])
    r.busy = false
    r.tlb = 0
    XCTAssertTrue(
      token.retire(requesterStoppedAndDrained: true, unit: u, memory: &m, registers: &r))
    XCTAssertEqual(r.writes, [0x28, 0xf8, 0xf8])
    XCTAssertTrue(vacant(&m))
  }
}
