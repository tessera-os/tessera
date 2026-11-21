import TarwinNetWire
import VirtioNetService
import XCTest

final class NetServiceTests: XCTestCase {
  func testDirectionBoundGrantAndUsedLength() {
    let r = NetFrame(direction: .receive, queue: 2, id: 5, epoch: 3, iova: 0x2000, bytes: 1514)!
      .record()
    func pending(
      _ queue: UInt32 = 2, _ epoch: UInt64 = 3, _ dir: NetDirection = .receive,
      _ h: UInt64 = 0x1000, _ max: UInt32 = 1514
    ) -> PendingNetFrame? {
      prepareNetFrame(
        r, epoch: epoch, queue: queue, direction: dir, maximum: max, header: h,
        grant: { $0 == 0x2000 && $1 == 1514 && $2 })
    }
    XCTAssertNil(pending(1))
    XCTAssertNil(pending(2, 4))
    XCTAssertNil(pending(2, 3, .transmit))
    XCTAssertNil(pending(2, 3, .receive, 0x1ff8))
    XCTAssertNil(pending(2, 3, .receive, 0x2010))
    XCTAssertNil(pending(2, 3, .receive, 0x1000, 1515))
    XCTAssertNil(
      prepareNetFrame(
        r, epoch: 3, queue: 2, direction: .receive, maximum: 1514, header: 0x1000,
        grant: { _, _, _ in false }))
    let p = pending()!
    XCTAssertNil(p.complete(cookie: 6, written: 100, flags: 0, gso: 0))
    XCTAssertNil(p.complete(cookie: 5, written: 26, flags: 1, gso: 0))
    XCTAssertNil(p.complete(cookie: 5, written: 25, flags: 0, gso: 0))
    XCTAssertNil(p.complete(cookie: 5, written: 1527, flags: 0, gso: 0))
    let done = p.complete(cookie: 5, written: 1526, flags: 0, gso: 0)!
    XCTAssertEqual(NetFrameDone(record: done.record())?.bytes, 1514)
  }
  func testWireRejectsMalformedReservedOrWrappedRecord() {
    XCTAssertNil(
      NetFrame(direction: .transmit, queue: 1, id: 2, epoch: 1, iova: .max - 11, bytes: 14))
    let f = NetFrame(
      direction: .transmit, queue: 1, id: .max, epoch: .max, iova: .max - 13, bytes: 14)!
    var r = f.record()
    XCTAssertEqual(NetFrame(record: r), f)
    r.words[0] |= 1 << 16
    XCTAssertNil(NetFrame(record: r))
    r = f.record()
    r.words[9] = 1
    XCTAssertNil(NetFrame(record: r))
    var c = NetFrameDone(direction: .receive, queue: 1, id: 2, epoch: 1, bytes: 14)!.record()
    c.words[7] = 42
    XCTAssertNil(NetFrameDone(record: c))
  }
}
