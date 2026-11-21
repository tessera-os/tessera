import Dispatch
import Synchronization
import XCTest
@testable import TarwinObject

private final class Shared: Sendable {
  let header: ObjectHeader
  let destroys = Atomic<Int>(0)
  init() {
    header = ObjectHeader(source: KoidSource(), ownerJob: 1, kind: TarwinKind.port, maximumRights: 7)!
  }
}

final class LifetimeTests: XCTestCase {
  func testKoidExhaustionNeverRecyclesZeroOrOne() {
    let source = KoidSource(after: .max - 1)
    XCTAssertEqual(source.issue(), .max)
    XCTAssertNil(source.issue())
  }

  func testPresenceCeilingIsEnforcedBeforeIssuingIdentity() {
    let ids = KoidSource()
    if let _ = ObjectHeader(source: ids, ownerJob: 8, kind: TarwinKind.presence, maximumRights: 3) {
      XCTFail("Presence cannot be duplicated or transferred")
    }
    XCTAssertEqual(ids.issue(), 1)
  }

  func testFinalReleaseHasOneWinnerAndCannotResurrect() {
    let shared = Shared()
    for _ in 1..<512 { XCTAssertTrue(shared.header.retainIfLive()) }
    DispatchQueue.concurrentPerform(iterations: 512) { _ in
      if shared.header.release() == .destroy {
        shared.destroys.wrappingAdd(1, ordering: .relaxed)
      }
    }
    XCTAssertEqual(shared.destroys.load(ordering: .relaxed), 1)
    XCTAssertFalse(shared.header.retainIfLive())
    XCTAssertEqual(shared.header.release(), .alreadyReleased)
  }

  func testConcurrentSignalWritersDoNotLoseBits() {
    let shared = Shared()
    DispatchQueue.concurrentPerform(iterations: 32) { bit in
      _ = shared.header.updateSignals(clear: 0, set: 1 << bit)
    }
    XCTAssertEqual(shared.header.signals, .max)
    XCTAssertEqual(shared.header.updateSignals(clear: .max, set: 3), 3)
  }
}
