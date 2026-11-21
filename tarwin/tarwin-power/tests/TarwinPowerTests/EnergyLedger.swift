import TarwinPower
import TarwinSched
import XCTest

private func withLedger(_ id: UInt64 = 17, _ body: (inout EnergyLedger) throws -> Void) rethrows {
  var a = [EnergyAccountSlot](repeating: .init(), count: 2)
  var c = [EnergyCPUSlot](repeating: .init(), count: 2)
  var d = [EnergyCounterSlot](repeating: .init(), count: 3)
  try a.withUnsafeMutableBufferPointer { accounts in
    try c.withUnsafeMutableBufferPointer { cpus in
      try d.withUnsafeMutableBufferPointer { counters in
        var book = EnergyLedger(id: id, accounts: accounts, cpus: cpus, counters: counters)!
        try body(&book)
      }
    }
  }
}

final class EnergyLedgerTests: XCTestCase {
  func testSimultaneousCPUsFrequencyChangeIdleAndUnknownPoint() throws {
    try withLedger { l in
      let app = try XCTUnwrap(l.openProcess(at: 0))
      let other = try XCTUnwrap(l.openProcess(at: 1))
      func rate(_ cpu: Int, _ hz: UInt64) -> UInt32? {
        switch (cpu, hz) {
        case (0, 100): return 4
        case (0, 200): return 12
        case (1, 100): return 8
        default: return nil
        }
      }
      XCTAssertTrue(l.switchCPU(0, at: 0, to: app, frequencyHz: 100, model: rate))
      XCTAssertTrue(l.switchCPU(1, at: 0, to: app, frequencyHz: 100, model: rate))
      XCTAssertNil(l.close(app))
      XCTAssertTrue(l.switchCPU(0, at: 500_000_000, to: app, frequencyHz: 200, model: rate))
      XCTAssertTrue(l.switchCPU(1, at: 750_000_000, to: other, frequencyHz: 300, model: rate))
      XCTAssertNil(l.sample(other, at: 749_999_999))
      XCTAssertFalse(l.switchCPU(0, at: 12, to: other, frequencyHz: 200, model: rate))
      XCTAssertEqual(l.sample(app, at: 1_000_000_000)?.microjoules, 14)
      XCTAssertEqual(l.sample(app, at: 1_000_000_000)?.runtimeNs, 1_750_000_000)
      XCTAssertTrue(l.switchCPU(0, at: 1_000_000_000, to: nil, frequencyHz: 0, model: rate))
      XCTAssertTrue(l.switchCPU(1, at: 1_000_000_000, to: nil, frequencyHz: 0, model: rate))
      let unknown = try XCTUnwrap(l.close(other))
      XCTAssertEqual(unknown.unmodelledNs, 250_000_000)
      XCTAssertEqual(unknown.microjoules, 0)
      XCTAssertEqual(l.close(app)?.cpu.microjoules, 14)
    }
  }

  func testResetLossReuseReplayAndSaturation() throws {
    try withLedger { l in
      let a = try XCTUnwrap(l.openProcess(at: 0))
      let g = try XCTUnwrap(l.bindCounter(at: 0, for: a, source: .gpu, baseline: 30))
      let d = try XCTUnwrap(l.bindCounter(at: 1, for: a, source: .display, baseline: 70))
      let r = try XCTUnwrap(l.bindCounter(at: 2, for: a, source: .radio, baseline: 0))
      XCTAssertTrue(l.report(g, sequence: 1, cumulative: 40))
      XCTAssertFalse(l.report(g, sequence: 1, cumulative: 100))
      XCTAssertFalse(l.finish(g, sequence: 2, cumulative: 0))
      XCTAssertNil(l.close(a))
      XCTAssertTrue(l.finish(g, sequence: 4, cumulative: 61))
      XCTAssertFalse(l.lost(g))
      XCTAssertTrue(l.lost(d))
      XCTAssertFalse(l.finish(d, sequence: 1, cumulative: 80))
      XCTAssertTrue(l.finish(r, sequence: 2, cumulative: .max))
      let done = try XCTUnwrap(l.close(a))
      XCTAssertEqual(done.gpu, 31)
      XCTAssertEqual(done.display, 0)
      XCTAssertEqual(done.lostReports, 1)
      XCTAssertEqual(done.microjoules, .max)
      let fresh = try XCTUnwrap(l.openProcess(at: 0))
      let next = try XCTUnwrap(l.bindCounter(at: 1, for: fresh, source: .display, baseline: 900))
      XCTAssertNil(l.bindCounter(at: 0, for: a, source: .radio, baseline: 0))
      XCTAssertFalse(l.switchCPU(0, at: 0, to: a, frequencyHz: 99) { _, _ in 9 })
      XCTAssertFalse(l.finish(d, sequence: 99, cumulative: 2000))
      XCTAssertTrue(l.finish(next, sequence: 1, cumulative: 910))
      XCTAssertEqual(l.close(fresh)?.microjoules, 10)
      try withLedger(18) { other in
        let new = try XCTUnwrap(other.openProcess(at: 0))
        XCTAssertNotEqual(new, a)
        XCTAssertNil(other.sample(a, at: 0))
      }
    }
  }

  func testDirectServiceChargesCallersSchedulingContext() throws {
    try withLedger { l in
      var cpu = BootstrapCPU(now: 0, identity: 1)
      let caller = try XCTUnwrap(l.openProcess(at: 0))
      let server = try XCTUnwrap(l.openProcess(at: 1))
      for tid in UInt64(1)...2 { XCTAssertTrue(cpu.create(id: tid, qos: SchedClass.normal)) }
      func charge(_ tid: UInt64, at ns: UInt64) {
        let process = tid == 0 ? nil : tid == 1 ? caller : server
        XCTAssertTrue(
          l.switchCPU(0, at: ns, to: process, frequencyHz: tid == 0 ? 0 : 1_000_000_000) { _, _ in
            1_000_000
          })
      }
      XCTAssertTrue(cpu.wake(2, now: 0))
      XCTAssertEqual(cpu.select(now: 0), 2)
      charge(cpu.charging, at: 0)
      let wait = try XCTUnwrap(cpu.waitForService(7, now: 300))
      XCTAssertTrue(cpu.wake(1, now: 300))
      XCTAssertEqual(cpu.select(now: 300), 1)
      charge(cpu.charging, at: 300)
      let loan = try XCTUnwrap(cpu.call(7, waiting: wait, now: 500) { true })
      XCTAssertEqual(cpu.running, 2)
      XCTAssertEqual(cpu.charging, 1)
      charge(cpu.charging, at: 500)
      XCTAssertTrue(cpu.reply(loan, now: 2300) { true })
      charge(cpu.charging, at: 2300)
      let charged = try XCTUnwrap(l.sample(caller, at: 2300))
      XCTAssertEqual(charged.runtimeNs, 2000)
      XCTAssertEqual(charged.cpu.microjoules, 2)
      XCTAssertEqual(l.sample(server, at: 2300)?.runtimeNs, 300)
    }
  }
}
