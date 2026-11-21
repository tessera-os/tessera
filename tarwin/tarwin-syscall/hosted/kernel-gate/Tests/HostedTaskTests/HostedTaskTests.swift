import Darwin
import Dispatch
import Foundation
import Synchronization
import TarwinABI
import TarwinArchHosted
import TarwinGateTransport
import TarwinHostedGate
import TarwinHostedImage
import TarwinKernelGate
import TarwinSyscall
import TarwinTaskProtocol
import TarwinTaskTransport
import TarwindKernel
import Testing

private final class TestHost: TarwindHost {
  func bootStage(_ name: String) {}
  func ready() {}
  func console(_ line: String) {}
  func panic(record: [UInt8]) { Issue.record("kernel panicked") }
}

private final class FixtureTrapSink: HostExceptionSink {
  let gates: [UInt64: UInt64]
  let fatalSite: UInt64
  let stopped = DispatchSemaphore(value: 0)
  let dispatcher = Mutex<KernelGateDispatch?>(nil)
  let faultThread = Mutex<UInt64?>(nil)

  init(gates: [UInt64: UInt64], fatalSite: UInt64) {
    self.gates = gates
    self.fatalSite = fatalSite
  }

  func handle(_ fault: HostException) -> HostExceptionDisposition {
    if fault.kind == .breakpoint, gates[fault.pc] != nil {
      faultThread.withLock { $0 = fault.thread.threadID }
      let x = fault.x
      let request = GateRequest(threadID: 1, number: x[16],
        arguments: CallRegisters(x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7]))
      guard dispatcher.withLock({ $0?.authorizeTrap(request) == true }) else { return .terminate }
      var resumed = fault.state
      resumed.pc += 4
      return .resume(resumed)
    }
    #expect(fault.kind == .breakpoint)
    #expect(fault.pc == fatalSite)
    stopped.signal()
    return .terminate
  }
}

@Test func spawnedTaskTrapsWaitsInKernelAndReadsTLSAfterReply() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = try taskExecutable()
  let kernel = try Tarwind.boot(.init(
    diskPath: directory.appendingPathComponent("disk").path,
    systemImagePath: directory.appendingPathComponent("image").path,
    panicRecordPath: directory.appendingPathComponent("panic").path,
    taskExecutablePath: executable), host: TestHost())
  defer { kernel.shutdown() }
  let process = kernel.createKernelProcess(name: "hosted-trap-test")
  var create = TarwinCallRegisters(number: TarwinCall.eventCreate)
  guard case .completed(let event) = kernel.gate.call(process: process, registers: &create),
    event.status == 0 else { Issue.record("event creation failed"); return }

  let page = TaskWindow.pageSize
  let text = TaskWindow.base
  let veneer = text + page
  let data = veneer + page
  let stack = data + 2 * page - 16
  let tcb = data + 128
  let scratchValue: UInt64 = 0x1020_3040_5060_7080
  let image = try HostedTrapRewrite.rewrite(text: [
    0xd53b_d053,  // mrs x19, tpidr_el0
    0xf900_0293,  // str x19, [x20]
    0xd400_0001,  // svc #0
    0xf900_0680,  // str x0, [x20, #8]
    0xf900_0a82,  // str x2, [x20, #16]
    0xd53b_d055,  // mrs x21, tpidr_el0
    0xf900_0e95,  // str x21, [x20, #24]
    0xf900_1291,  // str x17, [x20, #32]
    0xd400_1001,  // unlisted svc #0x80; must never reach XNU
  ], at: text, listedTraps: [text + 8], veneersAt: veneer)

  let sink = FixtureTrapSink(gates: image.gateTrapSites, fatalSite: text + 32)
  let exceptionPort = try HostExceptionPort(sink: sink)
  let exceptionSend = try exceptionPort.makeSend()
  let task = try TaskSpawner.spawn(executable: executable, exceptionPort: exceptionSend.rawName)
  defer {
    if waitpid(task.pid, nil, WNOHANG) == 0 {
      kill(task.pid, SIGKILL)
      while waitpid(task.pid, nil, 0) == -1 && errno == EINTR {}
    }
    withExtendedLifetime(exceptionPort) {}
  }
  let dispatcher = KernelGateDispatch(
    gate: kernel.gate, process: process, port: task.gateReceive, pid: task.pid)
  defer {
    sink.dispatcher.withLock { $0 = nil }
    dispatcher.close()
  }
  sink.dispatcher.withLock { $0 = dispatcher }
  let ports = try GatePortSet()
  try #require(ports.insert(task.gateReceive) == KERN_SUCCESS)

  func command(_ command: TaskCommand, entry: mach_port_t = 0) throws {
    try #require(try task.command(command, memoryEntry: entry, timeout: 2_000).get().status == KERN_SUCCESS)
  }
  try mapCode(image.text, at: text, page: page, command: command)
  try mapCode(image.veneers, at: veneer, page: page, command: command)

  var local: mach_vm_address_t = 0
  var dataSize = page * 2
  try #require(mach_vm_allocate(mach_task_self_, &local, dataSize, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
  defer { _ = mach_vm_deallocate(mach_task_self_, local, dataSize) }
  var dataEntry: mach_port_t = 0
  let rw = VM_PROT_READ | VM_PROT_WRITE
  try #require(mach_make_memory_entry_64(mach_task_self_, &dataSize, local, rw, &dataEntry, 0) == KERN_SUCCESS)
  defer { _ = mach_port_deallocate(mach_task_self_, dataEntry) }
  try command(.map(TaskMapping(
    address: data, length: dataSize, offset: 0, protection: UInt32(rw), copy: false)), entry: dataEntry)
  let report = try #require(UnsafePointer<UInt64>(bitPattern: UInt(local)))
  try command(.createThread(id: 1, entry: text, argument: 0, stack: stack, tls: tcb))
  let kernelThreadID = try task.threadIdentity(id: 1).get()
  var registers = InlineArray<31, UInt64>(repeating: 0)
  registers[0] = event.first
  registers[1] = 8
  registers[2] = .max
  registers[16] = TarwinCall.objectWait
  registers[17] = scratchValue
  registers[20] = data
  try command(.setThreadState(id: 1, state: TaskThreadState(
    registers: registers, stack: stack, pc: text, cpsr: 0)))
  try command(.resumeThread(id: 1))

  let call = try ports.receive(timeout: 2_000).get()
  #expect(sink.faultThread.withLock { $0 } == kernelThreadID)
  #expect(call.senderPID == task.pid)
  #expect(report[0] == tcb)
  try #require(dispatcher.dispatch(call) == .blocked)
  #expect(dispatcher.completeReady() == 0)
  #expect(sink.stopped.wait(timeout: .now()) == .timedOut)
  var signal = TarwinCallRegisters(number: TarwinCall.objectSignal, arguments: CallRegisters(event.first, 8))
  guard case .completed(let result) = kernel.gate.call(process: process, registers: &signal),
    result.status == 0 else { Issue.record("event signal failed"); return }
  try #require(dispatcher.completeReady() == 1)
  try #require(sink.stopped.wait(timeout: .now() + 2) == .success)
  #expect(report[1] == 0)
  #expect(report[2] & 8 == 8)
  #expect(report[3] == tcb)
  #expect(report[4] == scratchValue)
}

private func mapCode(
  _ words: [UInt32], at address: UInt64, page: UInt64,
  command: (TaskCommand, mach_port_t) throws -> Void
) throws {
  var local: mach_vm_address_t = 0
  try #require(mach_vm_allocate(mach_task_self_, &local, page, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
  defer { _ = mach_vm_deallocate(mach_task_self_, local, page) }
  let destination = try #require(UnsafeMutableRawPointer(bitPattern: UInt(local)))
  words.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
  sys_icache_invalidate(destination, Int(page))
  let rx = VM_PROT_READ | VM_PROT_EXECUTE
  try #require(mach_vm_protect(mach_task_self_, local, page, 0, rx) == KERN_SUCCESS)
  var length = page
  var entry: mach_port_t = 0
  try #require(mach_make_memory_entry_64(mach_task_self_, &length, local, rx, &entry, 0) == KERN_SUCCESS)
  defer { _ = mach_port_deallocate(mach_task_self_, entry) }
  try command(.map(TaskMapping(
    address: address, length: length, offset: 0, protection: UInt32(rx), copy: false)), entry)
}

private func taskExecutable() throws -> String {
  var image = Dl_info()
  try #require(dladdr(#dsohandle, &image) != 0)
  let name = try #require(image.dli_fname)
  var directory = URL(fileURLWithPath: String(cString: name)).deletingLastPathComponent()
  while directory.path != "/" {
    let executable = directory.appendingPathComponent("tarwin-task").path
    if FileManager.default.isExecutableFile(atPath: executable) { return executable }
    directory.deleteLastPathComponent()
  }
  throw CocoaError(.fileNoSuchFile)
}
