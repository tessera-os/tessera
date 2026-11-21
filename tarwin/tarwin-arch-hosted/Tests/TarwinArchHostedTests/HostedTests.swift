import Darwin
import Dispatch
import Foundation
import TarwinArchHosted
import XCTest

final class HostedTests: XCTestCase {
  func testClock() {
    let clock = HostClock()
    XCTAssertGreaterThan(clock.counterFrequency, 0)
    var previous = clock.monotonicNanos()
    for _ in 0..<1000 {
      let next = clock.monotonicNanos()
      XCTAssertGreaterThanOrEqual(next, previous)
      previous = next
    }
    XCTAssertGreaterThan(clock.absoluteNanos(), 0)
  }

  func testTimerDeadlineAndCancellation() throws {
    let queue = try HostEventQueue()
    XCTAssertTrue(try queue.wait(timeoutNanos: 0).isEmpty)
    let clock = HostClock()
    let deadline = clock.absoluteNanos() + 30_000_000
    let token = try queue.registerTimer(deadlineNanos: deadline)
    let events = try queue.wait(timeoutNanos: 1_000_000_000)
    let now = clock.absoluteNanos()
    XCTAssertEqual(events.map(\.token), [token])
    XCTAssertEqual(events.first?.kind, .timer)
    XCTAssertGreaterThanOrEqual(now, deadline)
    XCTAssertLessThan(now - deadline, 20_000_000)
    try queue.cancel(token)
    let cancelled = try queue.registerTimer(deadlineNanos: clock.absoluteNanos() + 10_000_000)
    try queue.cancel(cancelled)
    try queue.cancel(cancelled)
    XCTAssertTrue(try queue.wait(timeoutNanos: 30_000_000).isEmpty)
    XCTAssertThrowsError(try queue.registerTimer(deadlineNanos: 0, repeatingNanos: 0))
  }

  func testRepeatingTimer() throws {
    let queue = try HostEventQueue()
    let token = try queue.registerTimer(deadlineNanos: HostClock().absoluteNanos() + 5_000_000, repeatingNanos: 5_000_000)
    for _ in 0..<3 {
      XCTAssertEqual(try queue.wait(timeoutNanos: 1_000_000_000).first?.token, token)
    }
    try queue.cancel(token)
    XCTAssertTrue(try queue.wait(timeoutNanos: 20_000_000).isEmpty)
  }

  func testPipeReadWriteAndErrors() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    defer { close(fds[0]); close(fds[1]) }
    let queue = try HostEventQueue()
    XCTAssertThrowsError(try queue.registerFileDescriptor(-1))
    let readToken = try queue.registerFileDescriptor(fds[0])
    XCTAssertThrowsError(try queue.registerFileDescriptor(fds[0]))
    let writeToken = try queue.registerFileDescriptor(fds[1], write: true)
    XCTAssertEqual(try queue.wait(timeoutNanos: 1_000_000_000).first?.token, writeToken)
    try queue.cancel(writeToken)
    var byte: UInt8 = 42
    XCTAssertEqual(write(fds[1], &byte, 1), 1)
    let ready = try queue.wait(timeoutNanos: 1_000_000_000)
    XCTAssertEqual(ready.first?.token, readToken)
    XCTAssertEqual(ready.first?.kind, .read)
    XCTAssertEqual(ready.first?.data, 1)
    XCTAssertEqual(read(fds[0], &byte, 1), 1)
    try queue.cancel(readToken)
  }

  func testMachPortMessageAndOwnership() throws {
    let receive = try HostPort.receive()
    let name = receive.rawName
    do {
      let send = try receive.makeSend()
      XCTAssertEqual(send.kind, .send)
      let queue = try HostEventQueue()
      let token = try queue.registerMachPort(receive)
      XCTAssertThrowsError(try queue.registerMachPort(send))
      var header = mach_msg_header_t()
      header.msgh_bits = UInt32(MACH_MSG_TYPE_COPY_SEND)
      header.msgh_size = mach_msg_size_t(MemoryLayout.size(ofValue: header))
      header.msgh_remote_port = send.rawName
      XCTAssertEqual(mach_msg(&header, MACH_SEND_MSG, header.msgh_size, 0, 0, 0, 0), KERN_SUCCESS)
      let events = try queue.wait(timeoutNanos: 1_000_000_000)
      XCTAssertEqual(events.first?.token, token)
      XCTAssertEqual(events.first?.kind, .machPort)
      try queue.cancel(token)
      var buffer = [UInt8](repeating: 0, count: 256)
      let result = buffer.withUnsafeMutableBytes {
        mach_msg($0.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self), MACH_RCV_MSG | MACH_RCV_TIMEOUT,
          0, UInt32($0.count), name, 100, 0)
      }
      XCTAssertEqual(result, KERN_SUCCESS)
    }
    var refs: mach_port_urefs_t = 99
    XCTAssertEqual(mach_port_get_refs(mach_task_self_, name, MACH_PORT_RIGHT_SEND, &refs), KERN_SUCCESS)
    XCTAssertEqual(refs, 0)
  }

  func testProcessExit() throws {
    var attributes: posix_spawnattr_t?
    XCTAssertEqual(posix_spawnattr_init(&attributes), 0)
    defer { posix_spawnattr_destroy(&attributes) }
    XCTAssertEqual(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED)), 0)
    var pid: pid_t = 0
    let path = strdup("/usr/bin/true")!
    defer { free(path) }
    var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
    XCTAssertEqual(posix_spawn(&pid, path, nil, &attributes, &argv, environ), 0)
    defer {
      kill(pid, SIGKILL)
      var status: Int32 = 0
      waitpid(pid, &status, 0)
    }
    let queue = try HostEventQueue()
    let token = try queue.registerProcessExit(pid)
    XCTAssertEqual(kill(pid, SIGCONT), 0)
    let events = try queue.wait(timeoutNanos: 2_000_000_000)
    XCTAssertEqual(events.first?.token, token)
    XCTAssertEqual(events.first?.kind, .processExit)
    XCTAssertThrowsError(try queue.registerProcessExit(-1))
  }

  func testWorkerPolicy() throws {
    let cpu = HostCPU()
    XCTAssertGreaterThan(cpu.logicalCount, 0)
    XCTAssertGreaterThan(cpu.performanceCount, 0)
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let worker = try cpu.startWorker(name: "tarwin.test", qos: .background) {
      started.signal()
      finish.wait()
    }
    defer { finish.signal(); worker.waitUntilFinished() }
    XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
    try worker.apply(.interactive)
    try worker.apply(.default)
    try worker.apply(.realtime(periodNanos: 10_000_000, computationNanos: 1_000_000))
    try worker.apply(.background)
    XCTAssertThrowsError(try worker.apply(.realtime(periodNanos: 1, computationNanos: 2)))
  }

  func testExceptionDeliveryAndResume() throws {
    let result = try exceptionProbe(arguments: [])
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("EXC_BAD_ACCESS faultAddress=0x1000 registers=29"), result.output)
    XCTAssertTrue(result.output.contains("resumed after fault"), result.output)
  }

  func testExceptionTermination() throws {
    let result = try exceptionProbe(arguments: ["--terminate"])
    XCTAssertEqual(result.reason, .uncaughtSignal, result.output)
    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("faultAddress=0x1000"), result.output)
    XCTAssertFalse(result.output.contains("resumed after fault"), result.output)
  }

  private func exceptionProbe(arguments: [String]) throws -> (status: Int32, reason: Process.TerminationReason, output: String) {
    let binary = Bundle(for: HostedTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("HostedExceptionProbe")
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      XCTFail("exception worker failed to handle the fault within five seconds")
    }
    process.waitUntilExit()
    return (process.terminationStatus, process.terminationReason,
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  func testDeviceRegistryAndPlatform() throws {
    final class Device: HostDeviceProvider {
      let kind = "test-device"
      let receive: HostPort
      init() throws { receive = try HostPort.receive() }
      func open(slot: UInt32) throws -> HostPort {
        guard slot == 7 else { throw HostError("slot", code: EINVAL) }
        return try receive.makeSend()
      }
    }
    let platform = try HostPlatform.current()
    XCTAssertNil(platform.devices.lookup(kind: "test-device"))
    platform.devices.register(try Device())
    let provider = try XCTUnwrap(platform.devices.lookup(kind: "test-device"))
    XCTAssertEqual(provider.kind, "test-device")
    let port = try provider.open(slot: 7)
    XCTAssertEqual(port.kind, .send)
    do {
      let unexpected = try provider.open(slot: 8)
      XCTFail("invalid slot opened: \(unexpected.rawName)")
    } catch {}
  }
}
