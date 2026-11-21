import Darwin
import Dispatch
import Foundation
import TarwinTaskProtocol
@testable import TarwinTaskTransport
import Testing

@Test func checkInTransfersTheCorrectRights() throws {
  var bootstrap: mach_port_t = 0
  try #require(TaskMachMessage.newReceive(&bootstrap) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseReceive(bootstrap) }
  try #require(mach_port_insert_right(
    mach_task_self_, bootstrap, bootstrap, UInt32(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseSend(bootstrap) }

  let child = try TaskCheckIn.send(bootstrap: bootstrap).get()
  defer {
    TaskMachMessage.releaseSend(child.gateSend)
    TaskMachMessage.releaseReceive(child.commandReceive)
  }
  let kernel = try TaskCheckIn.receive(bootstrap: bootstrap, pid: getpid(), timeout: 500).get()
  defer {
    TaskMachMessage.releaseSend(kernel.commandSend)
    TaskMachMessage.releaseReceive(kernel.gateReceive)
  }
  #expect(child.commandReceive == kernel.commandSend)
  #expect(child.gateSend == kernel.gateReceive)

  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    defer { finished.signal() }
    let result = TaskCommandTransport.serveOne(on: child.commandReceive, timeout: 500) { command, entry in
      #expect(command.opcode == .terminate)
      #expect(entry == 0)
      return KERN_ABORTED
    }
    #expect((try? result.get()) == .terminate)
  }
  let response = try TaskCommandTransport.call(.terminate, on: kernel.commandSend, timeout: 500).get()
  #expect(response.status == KERN_ABORTED)
  #expect(finished.wait(timeout: .now() + .seconds(1)) == .success)
}

@Test func mapTransfersAnActualMemoryEntry() throws {
  var receiver: mach_port_t = 0
  try #require(TaskMachMessage.newReceive(&receiver) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseReceive(receiver) }
  try #require(mach_port_insert_right(
    mach_task_self_, receiver, receiver, UInt32(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseSend(receiver) }

  let length = mach_vm_size_t(getpagesize())
  var address: mach_vm_address_t = 0
  try #require(mach_vm_allocate(mach_task_self_, &address, length, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
  defer { _ = mach_vm_deallocate(mach_task_self_, address, length) }
  UnsafeMutablePointer<UInt64>(bitPattern: UInt(address))?.pointee = 0x5457
  var size = length
  var entry: mach_port_t = 0
  try #require(mach_make_memory_entry_64(
    mach_task_self_, &size, address, VM_PROT_READ, &entry, 0) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseSend(entry) }

  let port = receiver
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    defer { finished.signal() }
    let result = TaskCommandTransport.serveOne(on: port, timeout: 500) { command, entry in
      guard case .map(let mapping) = command else { return KERN_INVALID_ARGUMENT }
      var mapped: mach_vm_address_t = 0
      let map = mach_vm_map(
        mach_task_self_, &mapped, mapping.length, 0, VM_FLAGS_ANYWHERE, entry, mapping.offset,
        0, VM_PROT_READ, VM_PROT_READ, VM_INHERIT_NONE)
      guard map == KERN_SUCCESS else { return map }
      defer { _ = mach_vm_deallocate(mach_task_self_, mapped, length) }
      #expect(UnsafePointer<UInt64>(bitPattern: UInt(mapped))?.pointee == 0x5457)
      return KERN_SUCCESS
    }
    #expect((try? result.get()) == .map)
  }
  let mapping = TaskMapping(address: 0, length: length, offset: 0, protection: 1, copy: false)
  let response = try TaskCommandTransport.call(
    .map(mapping), on: port, memoryEntry: entry, timeout: 500).get()
  #expect(response.status == KERN_SUCCESS)
  #expect(finished.wait(timeout: .now() + .seconds(1)) == .success)
}

@Test func spawnedSandboxedTaskRunsLifecycleCommands() throws {
  let executable = try builtExecutable("tarwin-task")
  let child = try TaskSpawner.spawn(executable: executable)
  var reaped = false
  defer {
    if !reaped {
      kill(child.pid, SIGKILL)
      _ = waitpid(child.pid, nil, 0)
    }
  }

  let length = TaskWindow.pageSize
  var host: mach_vm_address_t = 0
  try #require(mach_vm_allocate(mach_task_self_, &host, length * 2, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
  defer { _ = mach_vm_deallocate(mach_task_self_, host, length * 2) }
  UnsafeMutablePointer<UInt32>(bitPattern: UInt(host))?.pointee = 0x1400_0000  // b .
  try #require(mach_vm_protect(
    mach_task_self_, host, length, 0, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS)
  var rx: mach_port_t = 0
  var rw: mach_port_t = 0
  var size = length
  try #require(mach_make_memory_entry_64(
    mach_task_self_, &size, host, VM_PROT_READ | VM_PROT_EXECUTE, &rx, 0) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseSend(rx) }
  try #require(mach_make_memory_entry_64(
    mach_task_self_, &size, host + length, VM_PROT_READ | VM_PROT_WRITE, &rw, 0) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseSend(rw) }

  let code = TaskWindow.base
  let data = code + length
  let stack = data + length - 16
  let read = UInt32(VM_PROT_READ)
  let exec = UInt32(VM_PROT_EXECUTE)
  let write = UInt32(VM_PROT_WRITE)
  func send(_ command: TaskCommand, entry: mach_port_t = 0) throws -> Int32 {
    try child.command(command, memoryEntry: entry, timeout: 1_000).get().status
  }
  try #require(try send(.map(TaskMapping(
    address: code, length: length, offset: 0, protection: read | exec, copy: false)), entry: rx)
    == KERN_SUCCESS)
  try #require(try send(.map(TaskMapping(
    address: data, length: length, offset: 0, protection: read | write, copy: true)), entry: rw)
    == KERN_SUCCESS)
  #expect(try send(.protect(address: data, length: length, protection: read)) == KERN_SUCCESS)
  #expect(try send(.protect(address: data, length: length, protection: read | write)) == KERN_SUCCESS)
  #expect(try send(.protect(address: data, length: length, protection: write | exec))
    == KERN_INVALID_ARGUMENT)

  let start = TaskCommand.createThread(id: 1, entry: code, argument: 0, stack: stack, tls: data)
  try #require(try send(start) == KERN_SUCCESS)
  #expect(try send(start) == KERN_INVALID_ARGUMENT)
  let registers = InlineArray<31, UInt64>(repeating: 0)
  #expect(try send(.setThreadState(id: 1, state: TaskThreadState(
    registers: registers, stack: stack, pc: code, cpsr: 0))) == KERN_SUCCESS)
  #expect(try send(.resumeThread(id: 1)) == KERN_SUCCESS)
  #expect(try send(.suspendThread(id: 1)) == KERN_SUCCESS)
  #expect(try send(.unmap(address: data, length: length)) == KERN_SUCCESS)
  #expect(try send(.terminate) == KERN_SUCCESS)
  var status: Int32 = -1
  reaped = waitpid(child.pid, &status, 0) == child.pid
  #expect(reaped)
  #expect(status == 0)
}

private func builtExecutable(_ name: String) throws -> String {
  var image = Dl_info()
  try #require(dladdr(#dsohandle, &image) != 0)
  let imageName = try #require(image.dli_fname)
  var dir = URL(fileURLWithPath: String(cString: imageName)).deletingLastPathComponent()
  while dir.path != "/", !FileManager.default.isExecutableFile(
    atPath: dir.appendingPathComponent(name).path) {
    dir.deleteLastPathComponent()
  }
  let executable = dir.appendingPathComponent(name).path
  try #require(FileManager.default.isExecutableFile(atPath: executable))
  return executable
}

@Test func spawnedTaskChecksInAfterBootstrapTraffic() throws {
  let child = try TaskSpawner.spawn(executable: builtExecutable("TaskCheckInExample"))
  var reaped = false
  defer {
    if !reaped {
      kill(child.pid, SIGKILL)
      _ = waitpid(child.pid, nil, 0)
    }
  }

  #expect(try child.command(.terminate, timeout: 1_000).get().status == KERN_SUCCESS)
  var status: Int32 = -1
  reaped = waitpid(child.pid, &status, 0) == child.pid
  #expect(reaped)
  #expect(status == 0)
}
