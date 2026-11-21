import XCTest

@testable import TRFS

final class ServerRingTests: XCTestCase {
  func testRecordsAreScopedAndReleaseSharesBeforeCompleting() {
    var c = FsChannel(volume: 10, epoch: 2, limit: 2)
    let root = VolumeNode(volume: 10, node: 0xfe)
    let none = VolumeNode(volume: 0, node: 0)
    let outside = VolumeNode(volume: 9, node: 0xfe)
    let valid: (UInt64) -> FsShare? = { id in
      return id == 11
        ? FsShare(volume: 10, id: id, backing: 88, offset: 0, length: 256, writable: true) : nil
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
    let valid: (UInt64) -> FsShare? = { _ in nil }
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

  func testGrantAliasesStayExcludedAcrossFailedRevocation() {
    var c = FsChannel(volume: 10, epoch: 1, limit: 3)
    let root = VolumeNode(volume: 10, node: 1)
    let none = VolumeNode(volume: 0, node: 0)
    func grant(_ id: UInt64) -> FsShare? {
      let offsets: [UInt64] = [0, 32, 63, 64, .max, 0]
      return FsShare(
        volume: id == 6 ? 11 : 10, id: id, backing: 34, offset: offsets[Int(id - 1)], length: 64,
        writable: id != 2)
    }
    func read(_ id: UInt64) -> Bool {
      c.begin(.read, root, none, 0, 0, 0, id, 64, grant, { _ in true })
    }
    XCTAssertFalse(
      c.begin(
        .lookup, root, none, 0, 2, 64, 3, 64, grant,
        { _ in
          XCTFail()
          return true
        }))
    XCTAssertTrue(read(1))
    XCTAssertFalse(read(3))
    XCTAssertTrue(read(4))
    XCTAssertFalse(c.finish(1, 1, 0, { _ in false }))
    XCTAssertFalse(read(3))
    XCTAssertTrue(c.finish(1, 1, 0, { _ in true }))
    XCTAssertFalse(read(3))
    XCTAssertTrue(c.finish(1, 2, 0, { _ in true }))
    XCTAssertTrue(read(3))
    XCTAssertFalse(read(5))
    XCTAssertFalse(read(6))
  }
}
