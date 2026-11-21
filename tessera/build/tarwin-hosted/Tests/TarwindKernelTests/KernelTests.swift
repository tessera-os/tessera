import Foundation
import XCTest
import TarwinArchHosted
import TarwinSched
import TarwinSyscall
import TarwinTime
@testable import TarwindKernel

final class RecordingHost: TarwindHost, @unchecked Sendable {
  let lock = NSLock()
  var stages: [String] = []
  var readyCount = 0
  var lines: [String] = []
  var panics = 0
  func bootStage(_ name: String) { lock.withLock { stages.append(name) } }
  func ready() { lock.withLock { readyCount += 1 } }
  func console(_ line: String) { lock.withLock { lines.append(line) } }
  func panic(record: [UInt8]) { lock.withLock { panics += 1 } }
}

final class KernelTests: XCTestCase {
  var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  func boot(_ host: RecordingHost) throws -> Tarwind {
    try Tarwind.boot(.init(diskPath: directory.appendingPathComponent("disk").path, systemImagePath: directory.appendingPathComponent("system").path, panicRecordPath: "panic", taskExecutablePath: "task"), host: host)
  }
  func testBootStagesPageAndShutdown() throws {
    let host = RecordingHost()
    let kernel = try boot(host)
    XCTAssertEqual(host.stages, ["time", "objects", "syscalls", "storage", "network", "scheduler", "ready"])
    XCTAssertEqual(host.readyCount, 1)
    let id = kernel.createKernelProcess(name: "test")
    XCTAssertTrue(kernel.containsProcess(id))
    let reader = TimePageReader(page: UnsafeRawBufferPointer(kernel.state.page))!
    XCTAssertNotNil(reader.read(counter: { kernel.state.clock.absoluteNanos() }))
    kernel.shutdown(); kernel.shutdown()
    XCTAssertFalse(kernel.containsProcess(id))
    var registers = TarwinCallRegisters(number: TarwinCall.timeRead)
    guard case .completed(let error) = kernel.gate.call(process: id, registers: &registers) else { return XCTFail() }
    XCTAssertEqual(error.code, 2)
    XCTAssertEqual(host.panics, 0)
  }
  func testSchedulingMappingIncludingExhaustedBudget() {
    func key(_ qos: UInt8, budget: UInt64 = 0) -> DispatchKey {
      DispatchKey(qos: qos, readySince: 0, virtualStart: 0, virtualDeadline: 0,
        classVirtualTime: 0, absoluteDeadline: 100, remainingBudget: budget, threadId: 1)
    }
    for qos in [SchedClass.idle, SchedClass.background] {
      guard case .background = hostedSchedulingPolicy(key(qos)) else { return XCTFail() }
    }
    for qos in [SchedClass.utility, SchedClass.normal] {
      guard case .default = hostedSchedulingPolicy(key(qos)) else { return XCTFail() }
    }
    for qos in [SchedClass.initiated, SchedClass.interactive, SchedClass.deadline] {
      guard case .interactive = hostedSchedulingPolicy(key(qos)) else { return XCTFail() }
    }
    guard case .realtime(let period, let budget) = hostedSchedulingPolicy(key(SchedClass.deadline, budget: 10), periodNanos: 100) else { return XCTFail() }
    XCTAssertEqual(period, 100); XCTAssertEqual(budget, 10)
  }
  func testEmptyRegistryUnknownCallAndInvalidMemory() throws {
    let kernel = try boot(RecordingHost())
    defer { kernel.shutdown() }
    var registers = TarwinCallRegisters(number: 999_999)
    guard case .completed(let missing) = kernel.gate.call(process: .init(value: 999), registers: &registers) else { return XCTFail() }
    XCTAssertEqual(missing.code, 2)
    let id = kernel.createKernelProcess(name: "empty")
    guard case .completed(let unsupported) = kernel.gate.call(process: id, registers: &registers) else { return XCTFail() }
    XCTAssertEqual(unsupported.code, 10)
    registers = TarwinCallRegisters(number: TarwinCall.syncWait32, arguments: CallRegisters(4096, 0, .max))
    guard case .completed(let invalid) = kernel.gate.call(process: id, registers: &registers) else { return XCTFail() }
    XCTAssertEqual(invalid.code, 1)
    XCTAssertNil(kernel.allocateKernelBuffer(process: id, count: 0))
  }
  func testHostThreadClassChangesApplyAndRejectInvalidRealtimeBudget() throws {
    final class Latch: @unchecked Sendable {
      let condition = NSCondition()
      var stopped = false
      func run() {
        condition.lock()
        while !stopped { condition.wait() }
        condition.unlock()
      }
      func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    }
    let latch = Latch()
    let thread = try HostCPU().startWorker(name: "tarwind.mapping-test") { latch.run() }
    defer { latch.stop(); thread.waitUntilFinished() }
    for qos in [SchedClass.background, SchedClass.normal, SchedClass.interactive] {
      let key = DispatchKey(qos: qos, readySince: 0, virtualStart: 0, virtualDeadline: 0,
        classVirtualTime: 0, absoluteDeadline: 0, remainingBudget: 0, threadId: 1)
      XCTAssertNoThrow(try applyHostedSchedulingChange(key, to: thread))
    }
    let invalid = DispatchKey(qos: SchedClass.deadline, readySince: 0, virtualStart: 0,
      virtualDeadline: 0, classVirtualTime: 0, absoluteDeadline: 100, remainingBudget: 100, threadId: 1)
    XCTAssertThrowsError(try applyHostedSchedulingChange(invalid, to: thread, periodNanos: 10))
  }
}
