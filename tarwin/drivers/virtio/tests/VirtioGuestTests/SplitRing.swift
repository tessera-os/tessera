import XCTest

@testable import VirtioGuest

final class SplitRingTests: XCTestCase {
  func testChainsArePublishedInOrderAndReleasedByPrivateOwnership() {
    var q = SplitQueue()
    XCTAssertTrue(!q.initialize(3))
    XCTAssertTrue(q.initialize(4))
    q.published = 65535
    q.consumed = 65535
    let parts = [
      Segment(iova: 0x1000, length: 16, deviceWrites: false),
      Segment(iova: 0x2000, length: 1, deviceWrites: true),
    ]
    var sequence: Int = 0
    let descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void = { slot, a, n, flags, next in
      if slot == 0 && a == 4096 && n == 16 && flags == 1 && next == 1 { sequence = 1 }
      if slot == 1 && flags == 2 && sequence == 1 { sequence = 2 }
    }
    let avail: (Int, UInt16) -> Void = { i, head in
      if sequence == 2 && i == 3 && head == 0 { sequence = 3 }
    }
    let release: (UInt16) -> Void = { idx in if sequence == 3 && idx == 0 { sequence = 4 } }
    XCTAssertTrue(q.submit(77, parts, descriptor, avail, release))
    XCTAssertTrue(sequence == 4)
    switch q.consume({ return 0 }, { i in return 0 }, { i in return 1 }) {
    case .completed(let result): XCTAssertTrue(result.cookie == 77 && result.written == 1)
    case .empty: XCTAssertTrue(false)
    case .broken: XCTAssertTrue(false)
    }
    XCTAssertTrue(q.outstanding == 0 && q.consumed == 0)
    XCTAssertTrue(
      q.consume({ return 1 }, { i in return 0 }, { i in return 0 }) == UsedResult.broken)
  }

  func testDeniesIdentityDmaAndUnimplementedRingFeatures() {
    XCTAssertTrue(isolatedSplitFeatures(0x1_0000_0000, 1) == 0)
    XCTAssertTrue(isolatedSplitFeatures(0xffff_ffff_ffff_ffff, 3) == 0x3_0000_0003)
  }
}
