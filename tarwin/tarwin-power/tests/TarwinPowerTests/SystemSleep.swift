import Dispatch
import TarwinPower
import XCTest

private final class PinnedGate: @unchecked Sendable {
  let gate = UnsafeMutablePointer<WakeGate>.allocate(capacity: 1)
  init() { gate.initialize(to: WakeGate()) }
  deinit {
    gate.deinitialize(count: 1)
    gate.deallocate()
  }
}

final class SystemSleepTests: XCTestCase {
  func testDependencyOrderAndKickBetweenLastCheckAndPark() {
    let p = PinnedGate()
    let locks = WakeLocks(limit: 2)
    var c = SystemSleep(
      nodes: 3,
      dependencies: [
        .init(dependent: 0, provider: 1),
        .init(dependent: 1, provider: 2),
      ], gate: p.gate)!
    guard case .admitted(let token) = c.admit(.connectedStandby, locks: locks) else {
      return XCTFail()
    }
    let sticky = DispatchSemaphore(value: 0)
    let drained = DispatchGroup()
    var trace: [String] = []
    let result = c.suspend(
      token,
      arm: { mode, t in
        trace.append("arm")
        return mode == .connectedStandby && t == token
      },
      sleep: {
        trace.append("down" + String($0))
        return true
      },
      park: { _, t in
        XCTAssertTrue(p.gate.pointee.armed(t))
        drained.enter()
        DispatchQueue.global().async {
          XCTAssertTrue(p.gate.pointee.signal(t, cause: .timer) { sticky.signal() })
          XCTAssertFalse(p.gate.pointee.signal(t, cause: .interrupt) { XCTFail() })
          drained.leave()
        }
        // The source has finished even before the idle primitive waits.
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sticky.wait(timeout: .now() + 2), .success)
        trace.append("wake")
      },
      resume: {
        trace.append("up" + String($0))
        return true
      },
      disarmAndDrain: { _ in
        trace.append("off")
        return true
      })
    XCTAssertEqual(result, .finished(.wake(.timer)))
    XCTAssertEqual(trace, ["arm", "down0", "down1", "down2", "wake", "up2", "up1", "up0", "off"])
    XCTAssertFalse(p.gate.pointee.signal(token, cause: .timer) { XCTFail() })
  }

  func testRollbackCannotSkipAProviderOrStartAgainBeforeDrain() {
    let p = PinnedGate()
    var locks = WakeLocks(limit: 1)
    let lock = locks.acquire(77, .device(2), true)
    var c = SystemSleep(
      nodes: 3, dependencies: [.init(dependent: 0, provider: 1), .init(dependent: 1, provider: 2)],
      gate: p.gate)!
    XCTAssertEqual(c.admit(.suspendToIdle, locks: locks), .blocked)
    XCTAssertTrue(locks.release(77, lock))
    guard case .admitted(let token) = c.admit(.suspendToIdle, locks: locks) else {
      return XCTFail()
    }
    var attempts: [Int] = []
    XCTAssertEqual(
      c.suspend(
        token, arm: { _, _ in true },
        sleep: { id in
          if id == 1 { p.gate.pointee.signal(token, cause: .networkPattern) {} }
          return true
        }, park: { _, _ in XCTFail() },
        resume: {
          attempts.append($0)
          return false
        },
        disarmAndDrain: { _ in
          XCTFail()
          return true
        }), .recovering)
    XCTAssertEqual(attempts, [1])
    XCTAssertEqual(c.admit(.connectedStandby, locks: locks), .busy)
    XCTAssertEqual(
      c.recover(
        resume: {
          attempts.append($0)
          return true
        }, disarmAndDrain: { _ in false }), .recovering)
    XCTAssertEqual(attempts, [1, 1, 0])
    XCTAssertEqual(
      c.recover(
        resume: { _ in
          XCTFail()
          return false
        }, disarmAndDrain: { $0 == token }), .finished(.wake(.networkPattern)))
    guard case .admitted(let newer) = c.admit(.suspendToIdle, locks: locks) else {
      return XCTFail()
    }
    XCTAssertFalse(p.gate.pointee.signal(token, cause: .timer) { XCTFail() })
    XCTAssertTrue(p.gate.pointee.signal(newer, cause: .policyChange) {})
    XCTAssertEqual(
      c.suspend(
        newer, arm: { _, _ in true },
        sleep: { _ in
          XCTFail()
          return false
        },
        park: { _, _ in XCTFail() },
        resume: { _ in
          XCTFail()
          return false
        }, disarmAndDrain: { _ in true }), .finished(.wake(.policyChange)))
  }

  func testFiniteHostSuspendCyclesAndPartialArmingFailures() {
    let p = PinnedGate()
    let locks = WakeLocks(limit: 0)
    var c = SystemSleep(nodes: 1, dependencies: [], gate: p.gate)!
    var last: UInt64 = 0
    var parks = 0
    var drains = 0
    var restored = 0
    for i in 0..<10_000 {
      guard case .admitted(let t) = c.admit(.suspendToIdle, locks: locks), t > last else {
        return XCTFail()
      }
      last = t
      let result = c.suspend(
        t, arm: { _, _ in i % 4 != 0 }, sleep: { _ in i % 4 != 1 },
        park: { _, _ in
          parks += 1
          if i % 4 == 2 { p.gate.pointee.signal(t, cause: .interrupt) {} }
        },
        resume: { _ in
          restored += 1
          return true
        },
        disarmAndDrain: { _ in
          drains += 1
          return true
        })
      let outcomes: [SleepExit] = [
        .armingFailed, .deviceRefused, .wake(.interrupt), .platformReturned,
      ]
      XCTAssertEqual(result, .finished(outcomes[i % 4]))
    }
    XCTAssertEqual(parks, 5000)
    XCTAssertEqual(restored, parks)
    XCTAssertEqual(drains, 10000)
  }
}
