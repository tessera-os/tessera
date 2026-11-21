import XCTest

@testable import TRFS

final class ServerRingTests: XCTestCase {
  func testRecordsAreScopedAndReleaseSharesBeforeCompleting() {
    var c = FsChannel(volume: 10, epoch: 2, limit: 2)
    let root = VolumeNode(volume: 10, node: 0xfe)
    let none = VolumeNode(volume: 0, node: 0)
    let outside = VolumeNode(volume: 9, node: 0xfe)
    let valid: (UInt64, UInt64, UInt32, Bool) -> Bool = { v, share, n, write in
      return v == 10 && share == 11 && n == 256 && write
    }
    var sent: Int = 0
    let post: (FsRecord) -> Bool = { r in
      let wire = fsRequestBytes(r)
      sent += 1
      return wire.count == 64 && wire[0] == 1 && wire[2] == 4 && wire[8] == 1 && wire[16] == 0xfe
        && wire[48] == 11 && wire[60] == 0 && wire[61] == 1
    }
    XCTAssertTrue(!c.begin(.rename, root, outside, 0, 0, 0, 0, 0, valid, post))
    XCTAssertTrue(!c.begin(.read, outside, none, 0, 0, 0, 11, 256, valid, post))
    XCTAssertTrue(!c.begin(.write, root, none, 0, 11, 256, 0, 0, valid, post))
    XCTAssertTrue(c.begin(.read, root, none, 0, 0, 0, 11, 256, valid, post))
    XCTAssertTrue(!c.begin(.read, root, none, 0, 0, 0, 11, 256, valid, post))
    XCTAssertTrue(sent == 1)
    let yes: (FsRecord) -> Bool = { r in return r.output == 11 }
    XCTAssertTrue(!c.finish(1, 1, 20, yes))
    XCTAssertTrue(!c.finish(2, 1, 257, yes))
    XCTAssertTrue(!c.finish(2, 1, 256, { r in return false }))
    XCTAssertTrue(c.live == 1)
    XCTAssertTrue(c.finish(2, 1, 256, yes))
    XCTAssertTrue(!c.finish(2, 1, 0, yes))
  }

  func testDeadServerCannotSubmitWhileRevocationIsPending() {
    var c = FsChannel(volume: 10, epoch: 2, limit: 1)
    let root = VolumeNode(volume: 10, node: 1)
    let none = VolumeNode(volume: 0, node: 0)
    let valid: (UInt64, UInt64, UInt32, Bool) -> Bool = { v, s, n, w in return false }
    let post: (FsRecord) -> Bool = { r in return true }
    var failed: UInt64 = 0
    let fail: (UInt64) -> Void = { id in failed = id }
    XCTAssertTrue(c.begin(.sync, root, none, 0, 0, 0, 0, 0, valid, post))
    XCTAssertTrue(!c.disconnect({ r in return false }, fail))
    XCTAssertTrue(failed == 0 && c.live == 1)
    XCTAssertTrue(!c.begin(.sync, root, none, 0, 0, 0, 0, 0, valid, post))
    XCTAssertTrue(c.disconnect({ r in return true }, fail))
    XCTAssertTrue(failed == 1 && c.live == 0)
  }
}
