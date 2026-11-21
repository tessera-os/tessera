import TarwinBlockWire
import XCTest

@testable import NVMeDriver

private final class Memory: NVMeAccess {
  var barBytes: UInt64 = 0x2000, words = [UInt64: UInt32](), registers = [UInt64: UInt32]()
  var clock: UInt64 = 0
  var events = [String]()
  func nowNs() -> UInt64 { clock }
  func pause() { clock += 500_000_000 }
  func load(_ addr: UInt64) -> UInt32 { words[addr] ?? 0 }
  func store(_ addr: UInt64, _ value: UInt32) { words[addr] = value }
  func register(_ at: UInt64) -> UInt32 { registers[at] ?? 0 }
  func setRegister(_ at: UInt64, _ v: UInt32) {
    registers[at] = v
    events.append("db")
  }
  func release() { events.append("release") }
  func acquire() { events.append("acquire") }
  func cqe(_ i: Int, head: Int, id: Int, phase: Int, status: Int = 0) {
    let at = UInt64(0x2000 + i * 16)
    store(at + 8, 1 << 16 | UInt32(head))
    store(at + 12, UInt32(status << 17 | phase << 16 | id))
  }
}
final class QueueTests: XCTestCase {
  func testPhaseWrapOutOfOrderAndCredit() throws {
    let m = Memory()
    var q = Queue(id: 1, depth: 3, sq: 0x1000, cq: 0x2000, stride: 4)
    XCTAssertNil(try q.poll(m))
    try q.submit(Command(1), 3, m)
    XCTAssertThrowsError(try q.submit(Command(1), 3, m))
    try q.submit(Command(2), 4, m)
    XCTAssertThrowsError(try q.submit(Command(2), 5, m))
    XCTAssertEqual(m.events, ["release", "db", "release", "db"])
    m.cqe(0, head: 2, id: 1, phase: 1)
    XCTAssertEqual(try q.poll(m)?.token, 4)
    XCTAssertEqual(m.events.suffix(3), ["acquire", "release", "db"])
    try q.submit(Command(0), 5, m)
    XCTAssertEqual(m.registers[0x1008], 0)
    m.cqe(1, head: 0, id: 0, phase: 1, status: 2)
    let fail = try q.poll(m)
    XCTAssertEqual(fail?.token, 3)
    XCTAssertEqual(fail?.status, 2)
    m.cqe(2, head: 0, id: 2, phase: 1)
    XCTAssertEqual(try q.poll(m)?.token, 5)
    XCTAssertTrue(q.idle)
    XCTAssertNil(try q.poll(m))
    try q.submit(Command(1), 6, m)
    m.cqe(0, head: 1, id: 3, phase: 0)
    XCTAssertEqual(try q.poll(m)?.token, 6)
  }
  func testMalformedCompletionFreezesWithoutReturningPins() throws {
    for (head, cid) in [(0, 0), (2, 0), (1, 1)] {
      let m = Memory()
      var q = Queue(id: 1, depth: 3, sq: 0x1000, cq: 0x2000, stride: 4)
      try q.submit(Command(2), 9, m)
      m.cqe(0, head: head, id: cid, phase: 1)
      XCTAssertThrowsError(try q.poll(m))
      XCTAssertTrue(q.poisoned)
      XCTAssertFalse(q.idle)
      XCTAssertThrowsError(try q.submit(Command(1), 11, m))
      XCTAssertNil(m.registers[0x100c])
    }
  }
  func testDirectPageCoverage() {
    func p(_ a: UInt64, _ n: UInt32, _ b: UInt64 = 0, _ m: UInt32 = 0) -> (UInt64, UInt64)? {
      var s = [BlockDmaVector(address: a, bytes: n)]
      if b != 0 { s.append(BlockDmaVector(address: b, bytes: m)) }
      return pagePointers(s)
    }
    XCTAssertEqual(p(0x1ffc, 4)?.1, 0)
    XCTAssertEqual(p(0x1ffc, 8)?.1, 0x2000)
    XCTAssertEqual(p(0x1ffc, 4, 0xc000, 4096)?.1, 0xc000)
    XCTAssertNil(p(0x1001, 4))
    XCTAssertNil(p(0x1000, 8193))
    XCTAssertNil(p(.max - 3, 8))
    XCTAssertNil(p(0x1ffc, 4, 0x1000, 4))
    XCTAssertNil(p(0x1ff8, 4, 0x3000, 4))
    XCTAssertNil(p(0x1000, 4096, 0x3004, 512))
  }
  func testFreshControllerAndTimeoutRetainPages() {
    let m = Memory()
    let pages = NVMePages(
      adminSubmission: 0x1000, adminCompletion: 0x2000, submission: 0x3000, completion: 0x4000,
      identify: 0x5000)!
    XCTAssertNil(
      NVMePages(
        adminSubmission: 0x1000, adminCompletion: 0x1000, submission: 0x3000, completion: 0x4000,
        identify: 0x5000))
    XCTAssertFalse(pages.disjoint(0xffc, 8))
    XCTAssertFalse(pages.disjoint(0x5fff, 1))
    XCTAssertTrue(pages.disjoint(0x6000, 4096))
    m.registers = [0: 63, 4: 32, 8: 0x10400, 20: 1]
    func start() -> NVMeError? {
      do {
        _ = try NVMeController.start(m, pages: pages, depth: 8, epoch: 1) { $0.first }
        return nil
      } catch { return error as? NVMeError }
    }
    XCTAssertEqual(start(), .configuration)
    XCTAssertTrue(m.events.isEmpty)
    m.registers[20] = 0
    XCTAssertEqual(start(), .timeout)
    XCTAssertEqual(m.registers[40], 0x1000)
    XCTAssertEqual(m.registers[20], 0x46_0001)
  }
}
