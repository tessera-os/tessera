import Darwin
import Dispatch
import Foundation
import TarwinABI
import TarwinGateTransport
import TarwinHostedGate
import TarwinKernelGate
import TarwinSyscall
import TarwindKernel
import Testing

private final class TestHost: TarwindHost {
  func bootStage(_ name: String) {}
  func ready() {}
  func console(_ line: String) {}
  func panic(record: [UInt8]) { Issue.record("kernel panicked") }
}

@Test func stubDispatchesOnlyAuthorizedCallsAndDoesNotHoldWorkerForWait() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let kernel = try Tarwind.boot(.init(
    diskPath: directory.appendingPathComponent("disk").path,
    systemImagePath: directory.appendingPathComponent("image").path,
    panicRecordPath: directory.appendingPathComponent("panic").path,
    taskExecutablePath: ""), host: TestHost())
  defer { kernel.shutdown() }
  let process = kernel.createKernelProcess(name: "gate-test")
  let ports = try GatePortSet()
  var gate: mach_port_t = 0
  try #require(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &gate) == KERN_SUCCESS)
  defer { dropReceive(gate) }
  try #require(mach_port_insert_right(
    mach_task_self_, gate, gate, UInt32(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
  defer { _ = mach_port_deallocate(mach_task_self_, gate) }
  try #require(ports.insert(gate) == KERN_SUCCESS)
  let dispatch = KernelGateDispatch(gate: kernel.gate, process: process, port: gate, pid: getpid())
  defer { dispatch.close() }

  let unauthorized = callStub(on: gate, thread: 1, number: TarwinCall.timeRead, rejected: true)
  #expect(dispatch.dispatch(try ports.receive(timeout: 2_000).get()) == .rejected)
  #expect(unauthorized.wait(timeout: .now() + 2) == .success)

  var create = TarwinCallRegisters(number: TarwinCall.eventCreate)
  guard case .completed(let event) = kernel.gate.call(process: process, registers: &create) else {
    Issue.record("event creation did not complete")
    return
  }
  try #require(event.status == 0)
  try #require(dispatch.authorizeTrap(GateRequest(
    threadID: 1, number: TarwinCall.objectWait, arguments: CallRegisters(event.first, 8, .max))))
  let wait = callStub(
    on: gate, thread: 1, number: TarwinCall.objectWait, a0: event.first, a1: 8, a2: .max, observed: 8)
  #expect(dispatch.dispatch(try ports.receive(timeout: 2_000).get()) == .blocked)
  #expect(dispatch.completeReady() == 0)
  #expect(wait.wait(timeout: .now()) == .timedOut)

  let signal = GateRequest(
    threadID: 2, number: TarwinCall.objectSignal, arguments: CallRegisters(event.first, 8))
  try #require(dispatch.authorizeTrap(signal))
  let immediate = callStub(on: gate, thread: 2, number: signal.number, a0: event.first, a1: 8)
  #expect(dispatch.dispatch(try ports.receive(timeout: 2_000).get()) == .replied)
  #expect(immediate.wait(timeout: .now() + 2) == .success)
  #expect(dispatch.completeReady() == 1)
  #expect(wait.wait(timeout: .now() + 2) == .success)
  #expect(dispatch.completeReady() == 0)
}

private func callStub(
  on gate: mach_port_t, thread: UInt64, number: UInt64, a0: UInt64 = 0,
  a1: UInt64 = 0, a2: UInt64 = 0, observed: UInt64? = nil, rejected: Bool = false
) -> DispatchSemaphore {
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    defer { done.signal() }
    var reply: mach_port_t = 0
    guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &reply) == KERN_SUCCESS
    else { Issue.record("could not allocate reply port"); return }
    defer { dropReceive(reply) }
    var frame: [UInt64] = [a0, a1, a2, 0, 0, 0, 0, 0, number]
    let status = frame.withUnsafeMutableBufferPointer {
      tarwinHostedGateCall($0.baseAddress!, thread, gate, reply)
    }
    if rejected {
      #expect(status != KERN_SUCCESS)
      return
    }
    #expect(status == KERN_SUCCESS)
    #expect(frame[0] == 0)
    #expect(frame[8] == number)
    if let observed { #expect(frame[2] & observed == observed) }
  }
  return done
}

private func dropReceive(_ port: mach_port_t) {
  _ = mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
}
