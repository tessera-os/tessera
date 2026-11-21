import XCTest

@testable import NativeDeviceManager

final class SupervisorTests: XCTestCase {
  func testWatchdogRejectsStalePongsAndWaitsForRevocationBeforeRestart() {
    var s = DriverSupervisor(apiYear: 26, apiMonth: 11, pingInterval: 10)
    let launch: (UInt64) -> Bool = { e in return true }
    let stalled: (UInt64, Bool) -> Bool = { e, r in return false }
    let reset: (UInt64, Bool) -> Bool = { e, r in return e == 1 && !r }
    let detach: (UInt64, Bool) -> Bool = { e, r in return e == 2 && r }
    var ping: UInt64 = 0
    let send: (UInt64, UInt64) -> Void = { e, c in ping = c }
    XCTAssertTrue(s.start(0, 26, 11, launch))
    XCTAssertTrue(s.ready(0, 1))
    s.watchdog(10, send)
    s.watchdog(20, send)
    XCTAssertTrue(ping == 20 && !s.pong(1, 10))
    s.watchdog(30, send)
    XCTAssertTrue(s.state == DriverState.quiescing && !s.start(30, 26, 11, launch))
    XCTAssertTrue(!s.quiesce(stalled))
    XCTAssertTrue(s.quiesce(reset))
    XCTAssertTrue(s.start(30, 26, 11, launch))
    XCTAssertTrue(!s.ready(30, 1))
    XCTAssertTrue(s.ready(30, 2))
    XCTAssertTrue(!s.failed(31, 1, false))
    s.remove()
    XCTAssertTrue(s.quiesce(detach))
    XCTAssertTrue(s.state == DriverState.removed && !s.start(40, 26, 11, launch))
  }

  func testFifthFailureInSlidingWindowStopsLaunching() {
    var s = DriverSupervisor(apiYear: 26, apiMonth: 11, pingInterval: 10)
    let launch: (UInt64) -> Bool = { e in return true }
    let delay: [UInt64] = [0, 100_000_000, 1_000_000_000, 10_000_000_000]
    var now: UInt64 = 1
    for i in 0..<5 {
      XCTAssertTrue(s.start(now, 26, 11, launch))
      XCTAssertTrue(s.failed(now, s.epoch, false))
      XCTAssertTrue(s.quiesce({ e, r in return true }))
      if i < 4 {
        XCTAssertTrue(s.resumeAt == now + delay[i])
        if delay[i] > 0 { XCTAssertTrue(!s.start(s.resumeAt - 1, 26, 11, launch)) }
        now = s.resumeAt
      }
    }
    XCTAssertTrue(s.state == DriverState.failed && !s.start(999_999_999_999, 26, 11, launch))
  }
}
