import TarwinBlockWire
import XCTest

@testable import UFSDriver

private final class Model: UFSAccess {
  var barBytes: UInt64 = 0xa0, clock: UInt64 = 1
  var regs: [UInt32: UInt32] = [Reg.cap: 1 << 24, Reg.host: 3, Reg.run: 1, Reg.version: 0x410]
  var mem = [UInt64: [UInt8]](), events = [String]()
  func register(_ at: UInt32) -> UInt32 { regs[at] ?? 0 }
  func setRegister(_ at: UInt32, _ value: UInt32) {
    regs[at] = value
    events.append("register")
  }
  func copyToDMA(_ a: UInt64, _ b: [UInt8]) -> Bool {
    mem[a] = b
    return true
  }
  func copyFromDMA(_ a: UInt64, count: Int) -> [UInt8]? { mem[a] }
  func acquire() { events.append("acquire") }
  func release() { events.append("release") }
  func nowNs() -> UInt64 { clock }
  func pause() { clock += 1 }
}
final class TransferTests: XCTestCase {
  private let pages = UFSPages(transferList: 0x2000, command: 0x5000)!
  func testColdControllerAndDMAExtentBoundaries() throws {
    XCTAssertNil(UFSPages(transferList: 0x1000, command: 0x1000))
    XCTAssertNil(UFSPages(transferList: 1, command: 0x1000))
    XCTAssertFalse(pages.permits(0x1ffc, 8))
    XCTAssertTrue(pages.permits(0x3000, 8192))
    XCTAssertFalse(pages.permits(.max - 1, 4))
    for (reg, value) in [(Reg.version, UInt32(0x300)), (Reg.enable, 1), (Reg.cap, 1 << 29)] {
      let m = Model()
      m.regs[reg] = value
      XCTAssertThrowsError(try Transfer(m, pages, 4).startLink())
      XCTAssertTrue(m.events.isEmpty)
    }
  }
  func testUnitIdentityProtectionAndCapacity() throws {
    var desc = [UInt8](repeating: 0, count: 45)
    desc.replaceSubrange(0..<4, with: [45, 2, 6, 1])
    desc[10] = 12
    desc.field(11, 0x1_0000_0005, 8, big: true)
    let limits = try unitLimits(desc, 6)
    XCTAssertEqual(limits.capacity, 0x1_0000_0005)
    XCTAssertEqual(limits.blockBytes, 4096)
    desc[5] = 2
    XCTAssertTrue(try unitLimits(desc, 6).readOnly)
    XCTAssertThrowsError(try unitLimits(desc, 7))
    for (at, value) in [(0, 0), (1, 3), (3, 0), (10, 31), (5, 3)] {
      var invalid = desc
      invalid[at] = UInt8(value)
      XCTAssertThrowsError(try unitLimits(invalid, 6))
    }
    desc.field(11, 0, 8, big: true)
    XCTAssertThrowsError(try unitLimits(desc, 6))
  }
  func testCDBLengthsAndNoSilentFUA() throws {
    func build(_ op: BlockOp, _ lba: UInt64, _ blocks: UInt64) throws -> [UInt8] {
      try diskCommand(
        BlockRequest(
          id: 1, epoch: 2, lba: lba, blocks: blocks, queue: 0, op: op, qos: .standard,
          payload: op == .flush ? BlockPayload() : BlockPayload(list: 0x8000, vectors: 1))!)
    }
    let small = try build(.write, 0x1020_3040, 0x203)
    XCTAssertEqual(small[0], 0x2a)
    XCTAssertEqual(Array(small[2..<6]), [0x10, 0x20, 0x30, 0x40])
    XCTAssertEqual(small[7], 2)
    XCTAssertEqual(small[8], 3)
    let large = try build(.read, UInt64.max - 1, 2)
    XCTAssertEqual(large[0], 0x88)
    XCTAssertEqual(large.be(2, 8), .max - 1)
    XCTAssertEqual(large.be(10, 4), 2)
    XCTAssertEqual(try build(.flush, 0, 0)[0], 0x35)
    XCTAssertEqual(try build(.fua, 0, 1)[1], 8)
    XCTAssertEqual(try build(.fua, 0x1_0000_0001, 1)[1], 8)
  }
  func testCapacityCrossCheckAndModeFlags() throws {
    var unit = [UInt8](repeating: 0, count: 45)
    unit.replaceSubrange(0..<4, with: [45, 2, 3, 1])
    unit[10] = 12
    unit.field(11, 257, 8, big: true)
    let limits = try unitLimits(unit, 3, mode: 0x90)
    XCTAssertTrue(limits.readOnly)
    XCTAssertTrue(limits.fua)
    XCTAssertFalse(try unitLimits(unit, 3).fua)
    var data = [UInt8](repeating: 0, count: 32)
    data.field(0, 256, 8, big: true)
    data.field(8, 4096, 4, big: true)
    try validateCapacity(limits, data)
    for i in [7, 11, 12] {
      var bad = data
      bad[i] ^= 1
      XCTAssertThrowsError(try validateCapacity(limits, bad))
    }
  }
  func testDescriptorOwnershipAndTerminalFaults() throws {
    let req = scsiRequest(lun: 6, cdb: Array(repeating: 0, count: 16), bytes: 8, read: true)
    let spans = [BlockDmaVector(address: 0x1_0000_0008, bytes: 8)]
    for fault in 0...8 {
      let m = Model()
      let t = Transfer(m, pages, 10)
      try t.submit(req, expect: 0x21, spans: spans)
      XCTAssertEqual(m.events, ["release", "register"])
      XCTAssertEqual(m.mem[pages.command + 1024], [8, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0])
      XCTAssertEqual(m.mem[pages.list]?[3], 0x15)
      XCTAssertEqual(m.mem[pages.list]?[24..<32], [128, 0, 128, 0, 1, 0, 0, 1])
      XCTAssertThrowsError(try t.submit(req, expect: 0x21, spans: spans))
      XCTAssertThrowsError(try t.stop())
      XCTAssertNil(try t.poll())
      var reply = [UInt8](repeating: 0, count: 512)
      reply[0] = 0x21
      reply[2] = 6
      switch fault {
      case 1: reply[0] = 0x36
      case 2: reply[2] = 7
      case 3: reply[3] = 1
      case 4: reply[10] = 2
      default: break
      }
      m.mem[pages.command + 512] = reply
      m.mem[pages.list + 8] = [fault == 5 ? 15 : 0, 0, 0, 0]
      m.regs[Reg.bell] = fault == 6 ? 1 : 0
      m.regs[Reg.completed] = fault == 7 ? 0 : fault == 8 ? 3 : 1
      m.clock = 11
      if fault == 0 {
        XCTAssertEqual(try t.poll(), reply)
        XCTAssertEqual(m.events.suffix(3), ["acquire", "register", "register"])
      } else {
        XCTAssertThrowsError(try t.poll())
        XCTAssertTrue(t.stopped)
        XCTAssertThrowsError(try t.submit(req, expect: 0x21, spans: spans))
      }
    }
  }
  func testBadPRDNeverRingsDoorbell() throws {
    let m = Model()
    let t = Transfer(m, pages, 10)
    m.regs[Reg.cap] = 0
    for (a, n) in [
      (UInt64(0x1004), UInt32(0)), (0x3001, 8), (0x3800, 7), (0x5000, 4), (0xffff_fffc, 8),
      (0x10000, 262148),
    ] {
      let req = scsiRequest(lun: 0, cdb: .init(repeating: 0, count: 16), bytes: n, read: true)
      XCTAssertThrowsError(
        try t.submit(req, expect: 0x21, spans: [BlockDmaVector(address: a, bytes: n)]))
      XCTAssertTrue(m.events.isEmpty)
      XCTAssertTrue(m.mem.isEmpty)
    }
  }
}
