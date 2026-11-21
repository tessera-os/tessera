import TarwinIPC
import XCTest

final class SubmissionTests: XCTestCase {
  func testBackpressurePinsOriginalRequestUntilCapturedAndBatchesDoorbells() {
    let m = SharedMemory(stride: 64)
    defer { withExtendedLifetime(m) {} }
    var kernel = PortSubmissions(fresh: m.view)!
    var user = RingEndpoint(fresh: m.view, completion: false, producer: true)!
    var op = RingRecord()
    for i: UInt32 in 0..<64 {
      op.words[0] = i
      op.words[15] = ~i
      XCTAssertEqual(user.push(op), .transferred(notifyPeer: false))
    }
    XCTAssertEqual(user.push(op), .wait)
    let pressure = kernel.drain(budget: 64) { r in
      XCTAssertEqual(r.words[0], 0)
      return false
    }
    XCTAssertEqual(pressure.stop, .capacity)
    XCTAssertEqual(pressure.count, 0)
    XCTAssertFalse(pressure.notifyPeer)
    XCTAssertEqual(m.cells[32].load(ordering: .acquiring), 0)
    m.cells[1024].store(91, ordering: .relaxed)
    var n: UInt32 = 0
    let part = kernel.drain(budget: 2) { r in
      XCTAssertEqual(r.words[0], n)
      XCTAssertEqual(r.words[15], ~n)
      n += 1
      return true
    }
    XCTAssertEqual(part.stop, .budget)
    XCTAssertEqual(part.count, 2)
    XCTAssertTrue(part.notifyPeer)
    let rest = kernel.drain(budget: .max) { r in
      XCTAssertEqual(r.words[0], n)
      n += 1
      return true
    }
    XCTAssertEqual(rest.count, 62)
    XCTAssertEqual(rest.stop, .idle)
    XCTAssertEqual(m.cells[32].load(ordering: .acquiring), 64)
    XCTAssertEqual(user.push(op), .transferred(notifyPeer: true))
  }

  func testHardTurnBoundAndRegressingPeerCannotCommitHeldCopy() {
    let m = SharedMemory(stride: 64)
    defer { withExtendedLifetime(m) {} }
    var kernel = PortSubmissions(fresh: m.view)!
    var user = RingEndpoint(fresh: m.view, completion: false, producer: true)!
    let op = RingRecord()
    for _ in 0..<64 { XCTAssertEqual(user.push(op), .transferred(notifyPeer: false)) }
    let first = kernel.drain(budget: .max) { _ in true }
    XCTAssertEqual(first.stop, .budget)
    XCTAssertEqual(first.count, 64)
    XCTAssertEqual(user.push(op), .transferred(notifyPeer: false))
    XCTAssertEqual(kernel.drain(budget: 1) { _ in false }.stop, .capacity)
    m.cells[16].store(64, ordering: .releasing)
    XCTAssertEqual(
      kernel.drain(budget: 1) { _ in
        XCTFail()
        return true
      }.stop, .invalidPeer)
    m.cells[16].store(65, ordering: .releasing)
    XCTAssertEqual(
      kernel.drain(budget: 1) { _ in
        XCTFail()
        return true
      }.stop, .invalidPeer)
    XCTAssertEqual(m.cells[32].load(ordering: .acquiring), 64)
    let wide = SharedMemory(stride: 128)
    if PortSubmissions(fresh: wide.view) != nil { XCTFail() }
  }
}
