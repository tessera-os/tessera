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
      return pagePointers(s, maxPages: 2).map { ($0[0], $0.count == 2 ? $0[1] : 0) }
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

  func testSingleListCoverageAndIdentifyLimits() {
    func plan(_ spans: [(UInt64, UInt32)]) -> [UInt64]? {
      pagePointers(spans.map { BlockDmaVector(address: $0.0, bytes: $0.1) }, maxPages: 513)
    }
    XCTAssertEqual(
      plan([(0x1ffc, 4), (0xb000, 3), (0xb003, 8189), (0xa000, 1)]),
      [0x1ffc, 0xb000, 0xc000, 0xa000])
    XCTAssertEqual(plan([(0x1ffc, 2 << 20)])?.count, 513)
    XCTAssertNil(plan([(0x1ffc, (2 << 20) + 5)]))
    XCTAssertNil(plan([(0x1ffc, 4), (0xb000, 8192), (0xc000, 8)]))
    XCTAssertNil(plan([(0x1ffc, 4), (0xb000, 3), (0xb004, 8188)]))
    XCTAssertEqual(transferLimit(mdts: 0, lists: true), 2 << 20)
    XCTAssertEqual(transferLimit(mdts: 1, lists: true), 8192)
    XCTAssertEqual(transferLimit(mdts: 3, lists: true), 32768)
    XCTAssertEqual(transferLimit(mdts: 255, lists: true), 2 << 20)
    XCTAssertEqual(transferLimit(mdts: 8, lists: false), 8192)
    XCTAssertNil(
      NVMePages(
        adminSubmission: 4096, adminCompletion: 8192,
        submission: 12288, completion: 16384, identify: 20480, prpLists: [20480]))
    let pages = NVMePages(
      adminSubmission: 4096, adminCompletion: 8192,
      submission: 12288, completion: 16384, identify: 20480, prpLists: [24576])!
    XCTAssertFalse(pages.disjoint(24575, 2))
  }

  func testOnlyMatchingCompletionReleasesPrivateList() throws {
    let m = Memory()
    var q = Queue(id: 1, depth: 4, sq: 0x1000, cq: 0x2000, stride: 4, lists: [0x9000])
    var cmd = Command(1)
    cmd.prp1 = 0xab00
    try q.submit(cmd, 1, m, listEntries: [0x1_0000_b000, 0xc000])
    XCTAssertEqual(m.load(0x1020), 0x9000)
    XCTAssertEqual(m.load(0x9000), 0xb000)
    XCTAssertEqual(m.load(0x9004), 1)
    try q.submit(Command(0), 2, m)
    m.cqe(0, head: 2, id: 1, phase: 1)
    XCTAssertEqual(try q.poll(m)?.token, 2)
    XCTAssertThrowsError(try q.submit(cmd, 3, m, listEntries: [0xd000, 0xe000])) {
      XCTAssertEqual($0 as? NVMeError, .busy)
    }
    XCTAssertEqual(m.load(0x9000), 0xb000)
    m.cqe(1, head: 2, id: 0, phase: 1)
    XCTAssertEqual(try q.poll(m)?.token, 1)
    try q.submit(cmd, 3, m, listEntries: [0xd000, 0xe000])
    XCTAssertEqual(m.load(0x9000), 0xd000)
    XCTAssertEqual(m.load(0x9008), 0xe000)
  }
}
