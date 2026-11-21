import Foundation
import XCTest
import TarwinArchHosted
import TarwinSyscall
import TarwindKernel

private final class RecordingHost: TarwindHost, @unchecked Sendable {
  let lock = NSLock()
  var stages: [String] = []
  var lines: [String] = []
  var readyCount = 0
  var panicCount = 0
  func bootStage(_ name: String) { lock.withLock { stages.append(name) } }
  func ready() { lock.withLock { readyCount += 1 } }
  func console(_ line: String) { lock.withLock { lines.append(line) } }
  func panic(record: [UInt8]) { lock.withLock { panicCount += 1 } }
}

final class HostedTests: XCTestCase {
  private func boot() throws -> (Tarwind, RecordingHost, TarwindProcessID) {
    let host = RecordingHost()
    let kernel = try Tarwind.boot(.init(diskPath: "unused.disk", systemImagePath: "unused.image",
      panicRecordPath: "unused.panic", taskExecutablePath: "unused.task"), host: host)
    XCTAssertEqual(host.stages, ["time", "objects", "syscalls", "scheduler", "ready"])
    XCTAssertEqual(host.readyCount, 1)
    return (kernel, host, kernel.createKernelProcess(name: "conformance"))
  }
  private func call(_ kernel: Tarwind, _ process: TarwindProcessID, _ number: UInt64,
    _ words: UInt64...) -> CallResult {
    var args = CallRegisters()
    for (i, word) in words.enumerated() { args[i] = word }
    var registers = TarwinCallRegisters(number: number, arguments: args)
    switch kernel.gate.call(process: process, registers: &registers) {
    case .completed(let result):
      XCTAssertEqual(registers.arguments.a0, result.status)
      XCTAssertEqual(registers.arguments.a2, result.first)
      return result
    case .blocked:
      XCTFail("unexpected blocking call")
      return CallResult(status: .max)
    }
  }
  private func wait(_ kernel: Tarwind, _ process: TarwindProcessID, _ event: UInt64,
    deadline: UInt64 = .max) -> TarwindContinuationID? {
    var registers = TarwinCallRegisters(number: TarwinCall.objectWait,
      arguments: CallRegisters(event, 8, deadline))
    guard case .blocked(let id) = kernel.gate.call(process: process, registers: &registers) else {
      XCTFail("expected blocked continuation"); return nil
    }
    return id
  }
  private func completion(_ kernel: Tarwind, _ id: TarwindContinuationID) -> CallResult? {
    let end = Date().addingTimeInterval(2)
    while Date() < end {
      if let result = kernel.gate.completion(id) { return result }
      Thread.sleep(forTimeInterval: 0.001)
    }
    XCTFail("continuation did not complete")
    return nil
  }
  func testObjectsHandlesRightsAndNamespaceIsolation() throws {
    let (kernel, _, process) = try boot()
    defer { kernel.shutdown() }
    let event = call(kernel, process, TarwinCall.eventCreate, 0)
    XCTAssertEqual(event.code, 0)
    let duplicate = call(kernel, process, TarwinCall.handleDuplicate, event.first, 128)
    XCTAssertEqual(duplicate.code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.objectSignal, duplicate.first, 8, 0).code, 4)
    XCTAssertEqual(call(kernel, process, TarwinCall.handleDuplicate, duplicate.first, 128).code, 4)
    let other = kernel.createKernelProcess(name: "other")
    XCTAssertEqual(call(kernel, other, TarwinCall.handleClose, event.first).code, 2)
    XCTAssertEqual(call(kernel, process, TarwinCall.handleClose, duplicate.first).code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.handleClose, duplicate.first).code, 2)
    XCTAssertEqual(call(kernel, process, TarwinCall.handleClose, event.first).code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.objectSignal, event.first, 8, 0).code, 2)
  }
  func testEventSignalImmediateWaitAndBadArguments() throws {
    let (kernel, _, process) = try boot()
    defer { kernel.shutdown() }
    XCTAssertEqual(call(kernel, process, TarwinCall.eventCreate, 1).code, 1)
    let event = call(kernel, process, TarwinCall.eventCreate, 0).first
    XCTAssertEqual(call(kernel, process, TarwinCall.objectWait, event, 0, .max).code, 1)
    XCTAssertEqual(call(kernel, process, TarwinCall.objectSignal, event, 8, 0).code, 0)
    let result = call(kernel, process, TarwinCall.objectWait, event, 8, .max)
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.first & 8, 8)
  }
  func testBlockingWaitCompletesFromAnotherThread() throws {
    let (kernel, _, process) = try boot()
    defer { kernel.shutdown() }
    let event = call(kernel, process, TarwinCall.eventCreate, 0).first
    let token = try XCTUnwrap(wait(kernel, process, event))
    XCTAssertNil(kernel.gate.completion(token))
    let done = expectation(description: "signaler returned")
    DispatchQueue.global().async {
      var registers = TarwinCallRegisters(number: TarwinCall.objectSignal, arguments: CallRegisters(event, 8, 0))
      if case .completed(let result) = kernel.gate.call(process: process, registers: &registers) {
        XCTAssertEqual(result.code, 0)
      } else { XCTFail() }
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    let result = try XCTUnwrap(completion(kernel, token))
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.first & 8, 8)
    XCTAssertNil(kernel.gate.completion(token))
    XCTAssertFalse(kernel.gate.cancel(token))
  }
  func testWaitTimeoutCancellationCloseAndShutdown() throws {
    let (kernel, _, process) = try boot()
    defer { kernel.shutdown() }
    let event = call(kernel, process, TarwinCall.eventCreate, 0).first
    let now = call(kernel, process, TarwinCall.timeRead, 0).first
    let timeout = try XCTUnwrap(wait(kernel, process, event, deadline: now + 5_000_000))
    XCTAssertEqual(completion(kernel, timeout)?.code, 25)
    let cancel = try XCTUnwrap(wait(kernel, process, event))
    XCTAssertTrue(kernel.gate.cancel(cancel))
    XCTAssertEqual(completion(kernel, cancel)?.code, 26)
    let close = try XCTUnwrap(wait(kernel, process, event))
    XCTAssertEqual(call(kernel, process, TarwinCall.handleClose, event).code, 0)
    XCTAssertEqual(completion(kernel, close)?.code, 26)
    let second = call(kernel, process, TarwinCall.eventCreate, 0).first
    let shutdown = try XCTUnwrap(wait(kernel, process, second))
    kernel.shutdown()
    XCTAssertEqual(completion(kernel, shutdown)?.code, 26)
  }
  func testChannelBytesAndMovedHandle() throws {
    let (kernel, _, process) = try boot()
    defer { kernel.shutdown() }
    let pair = call(kernel, process, TarwinCall.channelCreate, 0)
    XCTAssertEqual(pair.code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.channelPeek, pair.second).code, 24)
    let memory = try XCTUnwrap(kernel.allocateKernelBuffer(process: process, count: 128))
    let event = call(kernel, process, TarwinCall.eventCreate, 8).first
    memory.withUnsafeMutableBytes {
      $0[0] = 17; $0[1] = 42
      $0.storeBytes(of: event, toByteOffset: 16, as: UInt64.self)
    }
    XCTAssertEqual(call(kernel, process, TarwinCall.channelWrite, pair.first,
      memory.address, 2, memory.address + 16, 1).code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.handleClose, event).code, 2)
    let tooSmall = call(kernel, process, TarwinCall.channelRead, pair.second,
      memory.address + 32, 1, memory.address + 48, 1)
    XCTAssertEqual(tooSmall.code, 7)
    let read = call(kernel, process, TarwinCall.channelRead, pair.second,
      memory.address + 32, 2, memory.address + 48, 1)
    XCTAssertEqual(read.code, 0)
    XCTAssertEqual(read.first, 2); XCTAssertEqual(read.second, 1)
    let moved = memory.withUnsafeMutableBytes { bytes -> UInt64 in
      XCTAssertEqual(bytes[32], 17); XCTAssertEqual(bytes[33], 42)
      return bytes.load(fromByteOffset: 48, as: UInt64.self)
    }
    XCTAssertEqual(call(kernel, process, TarwinCall.objectWait, moved, 8, .max).code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.channelRead, pair.second, 4096, 2, 8192, 1).code, 1)
    XCTAssertEqual(call(kernel, process, TarwinCall.handleClose, pair.first).code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.channelPeek, pair.second).code, 27)
  }
  func testMonotonicTimeAndSplitAddressWait() throws {
    let (kernel, _, process) = try boot()
    defer { kernel.shutdown() }
    var last: UInt64 = 0
    for _ in 0..<100 {
      let time = call(kernel, process, TarwinCall.timeRead, 0)
      XCTAssertEqual(time.code, 0); XCTAssertGreaterThanOrEqual(time.first, last); last = time.first
    }
    XCTAssertEqual(call(kernel, process, TarwinCall.timeRead, 99).code, 1)
    let buffer = try XCTUnwrap(kernel.allocateKernelBuffer(process: process, count: 8))
    var registers = TarwinCallRegisters(number: TarwinCall.syncWait32,
      arguments: CallRegisters(buffer.address, 0, .max))
    guard case .blocked(let token) = kernel.gate.call(process: process, registers: &registers) else { return XCTFail() }
    let wake = call(kernel, process, TarwinCall.syncWake, buffer.address, 1)
    XCTAssertEqual(wake.code, 0); XCTAssertEqual(wake.first, 1)
    XCTAssertEqual(completion(kernel, token)?.code, 0)
  }
  func testInjectedExceptionTerminatesOnlyFaultingProcessWithoutPanic() throws {
    let (kernel, host, process) = try boot()
    defer { kernel.shutdown() }
    let other = kernel.createKernelProcess(name: "survivor")
    let event = call(kernel, process, TarwinCall.eventCreate, 0).first
    let token = try XCTUnwrap(wait(kernel, process, event))
    kernel.injectException(process: process, kind: .badAccess, code: 1, faultAddress: 0x1234)
    XCTAssertFalse(kernel.containsProcess(process))
    XCTAssertTrue(kernel.containsProcess(other))
    XCTAssertEqual(completion(kernel, token)?.code, 26)
    XCTAssertEqual(call(kernel, process, TarwinCall.timeRead, 0).code, 2)
    XCTAssertEqual(call(kernel, other, TarwinCall.timeRead, 0).code, 0)
    XCTAssertTrue(host.lines.contains { $0.contains("badAccess") && $0.contains("4660") })
    XCTAssertEqual(host.panicCount, 0)
  }
  func testManyBlockedCallsLeaveGateAvailable() throws {
    let (kernel, _, process) = try boot()
    defer { kernel.shutdown() }
    let event = call(kernel, process, TarwinCall.eventCreate, 0).first
    var tokens: [TarwindContinuationID] = []
    for _ in 0..<32 { tokens.append(try XCTUnwrap(wait(kernel, process, event))) }
    XCTAssertEqual(call(kernel, process, TarwinCall.timeRead, 0).code, 0)
    XCTAssertEqual(call(kernel, process, TarwinCall.objectSignal, event, 8, 0).code, 0)
    for token in tokens { XCTAssertEqual(completion(kernel, token)?.code, 0) }
  }
}
