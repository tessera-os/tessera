import Dispatch
import XCTest
@testable import TarwinSync

private final class SharedDomain: Sendable {
  let epoch = EpochDomain()
}

final class EpochTests: XCTestCase {
  func testReclaimWaitsForOldReadersButNotNewReaders() {
    let shared = SharedDomain()
    let ready = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      shared.epoch.withRead {
        ready.signal()
        _ = resume.wait(timeout: .now() + 5)
      }
      done.signal()
    }
    XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    guard let ticket = shared.epoch.beginGracePeriod() else { return XCTFail() }
    XCTAssertNil(shared.epoch.beginGracePeriod())
    XCTAssertFalse(shared.epoch.finishGracePeriod(ticket))
    resume.signal()
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    shared.epoch.withRead {
      XCTAssertTrue(shared.epoch.finishGracePeriod(ticket))
      XCTAssertFalse(shared.epoch.finishGracePeriod(ticket))
      let next = shared.epoch.beginGracePeriod()!
      XCTAssertNotEqual(next, ticket)
      XCTAssertFalse(shared.epoch.finishGracePeriod(next))
      XCTAssertFalse(shared.epoch.finishGracePeriod(ticket))
    }
  }
}
