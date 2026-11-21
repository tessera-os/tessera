import XCTest

@testable import TRFS

final class BoundaryTests: XCTestCase {
  func testFollowsConfinedLinksButNotAboveTheCapability() {
    let lookup: (UInt64, [UInt8]) -> Entry = { dir, name in
      if name.count != 1 { return .missing }
      if dir == 5 && name[0] == 97 { return .directory(6) }
      if dir == 5 && name[0] == 98 { return .file(9) }
      if dir == 6 && name[0] == 99 { return .symlink([46, 46, 47, 98]) }
      if dir == 5 && name[0] == 100 { return .symlink([46, 46, 47, 98]) }
      if dir == 5 && name[0] == 101 { return .symlink([101]) }
      return .missing
    }
    XCTAssertTrue(scopedLookup(5, [97, 47, 99], true, lookup) == Walk.found(9))
    XCTAssertTrue(scopedLookup(5, [97, 47, 99], false, lookup) == Walk.notDirectory)
    XCTAssertTrue(scopedLookup(5, [100], true, lookup) == Walk.escape)
    XCTAssertTrue(scopedLookup(5, [101], true, lookup) == Walk.loop)
    XCTAssertTrue(scopedLookup(5, [46, 46], true, lookup) == Walk.invalid)
    XCTAssertTrue(scopedLookup(5, [98, 47, 98], true, lookup) == Walk.notDirectory)
  }

  func testNeverSubmitsPlaintextOnEncryptionFailure() {
    let u = EncryptedUnit(block: 11, tweak: 99, keyObject: 1)
    var sent: Int = 0
    var cleared: UInt64 = 0
    let io: (UInt64, UInt64) -> Bool = { block, page in
      sent += 1
      return block == 11 && page == 3
    }
    let clear: (UInt64) -> Void = { page in cleared = page }
    XCTAssertTrue(!encryptedWriteback(u, 2, 3, { k, t, p, c in return false }, io, clear))
    XCTAssertTrue(sent == 0 && cleared == 3)
    XCTAssertTrue(
      encryptedWriteback(
        u, 2, 3, { k, t, p, c in return k == 1 && t == 99 && p == 2 && c == 3 }, io, clear))
    XCTAssertTrue(sent == 1)
    XCTAssertTrue(!encryptedPageIn(u, 2, 2, io, { k, t, c, p in return true }, clear))
    XCTAssertTrue(!encryptedPageIn(u, 2, 3, io, { k, t, c, p in return false }, clear))
    XCTAssertTrue(cleared == 2)
  }
}
