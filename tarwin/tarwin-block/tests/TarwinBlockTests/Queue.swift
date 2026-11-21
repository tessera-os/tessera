import XCTest

@testable import TarwinBlock

final class QueueTests: XCTestCase {
  func cmd(_ op: BlockOp, _ lba: UInt64, _ blocks: UInt64, _ qos: IoQos, _ queue: UInt32)
    -> BlockCommand
  {
    return BlockCommand(op: op, lba: lba, blocks: blocks, qos: qos, queue: queue)
  }

  func testForegroundBypassesLowWithoutReorderingOverlaps() {
    var q = BlockQueue(capacity: 1024, queueCount: 1, pendingLimit: 64, depth: 32)
    let a = q.enqueue(cmd(.write, 0, 4, .background, 0))
    let b = q.enqueue(cmd(.write, 4, 4, .utility, 0))
    XCTAssertTrue(q.dispatch(0) == b)
    XCTAssertTrue(q.dispatch(0) == 0)
    let c = q.enqueue(cmd(.read, 3, 1, .interactive, 0))
    let d = q.enqueue(cmd(.read, 8, 1, .interactive, 0))
    XCTAssertTrue(q.dispatch(0) == d)
    XCTAssertTrue(q.complete(0, 1, b))
    XCTAssertTrue(q.dispatch(0) == a)
    XCTAssertTrue(q.complete(0, 1, a))
    XCTAssertTrue(q.dispatch(0) == c)
  }

  func testAtMostOneIssuedLowerClassPrecedesInteractiveRead() {
    var q = BlockQueue(capacity: 64, queueCount: 1, pendingLimit: 8, depth: 8)
    let active = q.enqueue(cmd(.read, 0, 1, .standard, 0))
    XCTAssertEqual(q.dispatch(0), active)
    _ = q.enqueue(cmd(.read, 1, 1, .initiated, 0))
    XCTAssertEqual(q.dispatch(0), 0)
    let ui = q.enqueue(cmd(.read, 2, 1, .interactive, 0))
    XCTAssertEqual(q.dispatch(0), ui)
  }

  func testFlushSpansQueuesAndRestartRejectsStaleCompletion() {
    var q = BlockQueue(capacity: 64, queueCount: 2, pendingLimit: 64, depth: 4)
    let a = q.enqueue(cmd(.write, 0, 1, .utility, 1))
    let f = q.enqueue(cmd(.flush, 0, 0, .standard, 0))
    let b = q.enqueue(cmd(.write, 2, 1, .initiated, 1))
    XCTAssertTrue(q.dispatch(0) == 0 && q.dispatch(1) == a)
    XCTAssertTrue(q.restart())
    XCTAssertTrue(!q.complete(1, 1, a))
    XCTAssertTrue(q.dispatch(1) == a && q.complete(1, 2, a))
    XCTAssertTrue(q.dispatch(1) == 0 && q.dispatch(0) == f)
    XCTAssertTrue(q.complete(0, 2, f))
    XCTAssertTrue(q.dispatch(1) == b)
    var last: UInt64 = 0
    q.removeDevice({ id in last = id })
    XCTAssertTrue(last == b && !q.complete(1, 2, b))
    XCTAssertTrue(q.enqueue(cmd(.read, 0, 1, .standard, 0)) == 0)
  }

  func testRefusesOverflowAndMalformedFlush() {
    var q = BlockQueue(capacity: 0xffff_ffff_ffff_ffff, queueCount: 1, pendingLimit: 1, depth: 1)
    XCTAssertTrue(q.enqueue(cmd(.fua, 0xffff_ffff_ffff_fffe, 2, .interactive, 0)) == 0)
    XCTAssertTrue(q.enqueue(cmd(.flush, 0, 1, .interactive, 0)) == 0)
    XCTAssertTrue(q.enqueue(cmd(.write, 0, 1, .standard, 1)) == 0)
  }
}
