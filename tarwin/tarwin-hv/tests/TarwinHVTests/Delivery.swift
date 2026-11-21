import Testing
import TarwinSyscall
@testable import TarwinHV

@Test func scaledDeadlinesRoundUpAndOverflowIsRejected() throws {
  let clock = try #require(GuestClock(host: 100, guest: 20, numerator: 3, denominator: 2))
  #expect(clock.ticks(at: 99) == nil)
  #expect(clock.ticks(at: 103) == 24)
  #expect(clock.hostDeadline(for: 24) == 103)
  let extreme = try #require(GuestClock(host: 0, guest: 1, numerator: .max, denominator: 1))
  #expect(extreme.ticks(at: 1) == nil)
  #expect(extreme.ticks(at: 2) == nil)
  var timer = GuestComparator(compare: 24, enabled: true, masked: false)
  var changes = [Bool]()
  func deliver(_ level: Bool) -> Bool { changes.append(level); return true }
  #expect(timer.update(at: 23, setLine: deliver) == true)
  #expect(timer.update(at: 24, setLine: { _ in false }) == false)
  #expect(timer.update(at: 25, setLine: deliver) == true)
  #expect(timer.update(at: 26, setLine: deliver) == true)
  timer.masked = true
  #expect(timer.update(at: 26, setLine: deliver) == true)
  #expect(changes == [true, false])
}

@Test func guestFilePrioritizesAndRetainsMaskedInterrupts() throws {
  var file = try #require(GuestInterruptFile(lastID: 127))
  #expect(file.post(0) == false)
  #expect(file.post(128) == false)
  #expect(file.post(65) == true)
  #expect(file.post(2) == true)
  #expect(file.setEnabled(65, true) == true)
  #expect(file.setEnabled(2, true) == true)
  #expect(!file.lineAsserted)
  file.delivery = true
  file.threshold = 2
  #expect(!file.lineAsserted)
  file.threshold = 65
  #expect(file.lineAsserted)
  #expect(file.claim() == 2)
  #expect(file.claim() == 0)
  file.threshold = 0
  #expect(file.claim() == 65)
}

@Test func cancellationDuringEntryUsesIndependentStateAccess() throws {
  var cpu = VirtualCpuState(creator: 7)
  var kicks = 0
  let result = runCpu(TarwinCall.virtualCpuRun, thread: 7, arm: { cpu.begin($0) }, enter: {
    #expect(interruptRun(TarwinCall.virtualCpuRequestExit, request: { cpu.requestExit() }, kick: { kicks += 1 }))
    return ExitRecord(reason: .mmio, address: 7, width: 4, write: false, data: 4, registerIndex: 1)
  }, finish: { cpu.finish($0) })
  #expect(try result.get().reason == .canceled)
  #expect(!cpu.running && !cpu.exitRequested && kicks == 1)
}
