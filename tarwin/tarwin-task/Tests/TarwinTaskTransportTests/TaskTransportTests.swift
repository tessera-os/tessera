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
  #expect(try send(.protect(address: TaskGatePage.address, length: length, protection: write))
    == KERN_INVALID_ARGUMENT)
  #expect(try send(.unmap(address: TaskGatePage.address, length: length)) == KERN_INVALID_ARGUMENT)

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

@Test func spawnedTaskSnapshotCopiesLivePrivatePagesAndIsolatesLaterWrites() throws {
  let executable = try builtExecutable("tarwin-task")
  let parent = try TaskSpawner.spawn(executable: executable)
  defer { terminateAndReap(parent) }
  let child = try TaskSpawner.spawn(executable: executable)
  defer { terminateAndReap(child) }

  let page = TaskWindow.pageSize
  let code = TaskWindow.base
  let data = code + page
  let reportAddress = data + page
  var backing: UInt64 = 0
  try #require(mach_vm_allocate(mach_task_self_, &backing, 3 * page, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
  defer { _ = mach_vm_deallocate(mach_task_self_, backing, 3 * page) }
  let instructions = try #require(UnsafeMutablePointer<UInt32>(bitPattern: UInt(backing)))
  instructions[0] = 0xf900_0001 // str x1, [x0]
  instructions[1] = 0xf940_0002 // ldr x2, [x0]
  instructions[2] = 0xf900_0062 // str x2, [x3]
  instructions[3] = 0x1400_0000 // b .
  sys_icache_invalidate(instructions, 16)
  let rx = VM_PROT_READ | VM_PROT_EXECUTE
  let rw = VM_PROT_READ | VM_PROT_WRITE
  try #require(mach_vm_protect(mach_task_self_, backing, page, 0, rx) == KERN_SUCCESS)
  func entry(_ offset: UInt64, _ protection: Int32) throws -> mach_port_t {
    var size = page
    var port: mach_port_t = 0
    try #require(mach_make_memory_entry_64(
      mach_task_self_, &size, backing + offset, protection, &port, 0) == KERN_SUCCESS)
    return port
  }
  let text = try entry(0, rx)
  defer { TaskMachMessage.releaseSend(text) }
  let original = try entry(page, rw)
  defer { TaskMachMessage.releaseSend(original) }
  let reporting = try entry(2 * page, rw)
  defer { TaskMachMessage.releaseSend(reporting) }
  let report = try #require(UnsafePointer<UInt64>(bitPattern: UInt(backing + 2 * page)))
  let originalBytes = try #require(UnsafePointer<UInt64>(bitPattern: UInt(backing + page)))
  func command(_ task: SpawnedTask, _ command: TaskCommand, entry: mach_port_t = 0) throws {
    try #require(try task.command(command, memoryEntry: entry, timeout: 2_000).get().status == KERN_SUCCESS)
  }
  func map(_ task: SpawnedTask, _ address: UInt64, _ entry: mach_port_t, _ protection: Int32,
    copy: Bool = false) throws {
    try command(task, .map(TaskMapping(
      address: address, length: page, offset: 0, protection: UInt32(protection), copy: copy)), entry: entry)
  }
  for task in [parent, child] {
    try map(task, code, text, rx)
    try map(task, reportAddress, reporting, rw)
  }
  try map(parent, data, original, rw, copy: true)
  let stack = reportAddress + page - 16
  func run(_ task: SpawnedTask, pc: UInt64, value: UInt64, reportSlot: Int) throws {
    var registers = InlineArray<31, UInt64>(repeating: 0)
    registers[0] = data
    registers[1] = value
    registers[3] = reportAddress + UInt64(reportSlot * 8)
    try command(task, .setThreadState(id: 1, state: TaskThreadState(
      registers: registers, stack: stack, pc: pc, cpsr: 0)))
    try command(task, .resumeThread(id: 1))
  }
  func waitForReport(_ slot: Int, value: UInt64) throws {
    let deadline = DispatchTime.now() + .seconds(2)
    while report[slot] != value && DispatchTime.now() < deadline { usleep(1_000) }
    try #require(report[slot] == value)
  }
  try command(parent, .createThread(id: 1, entry: code, argument: 0, stack: stack, tls: 0))
  try run(parent, pc: code, value: 0x1234, reportSlot: 0)
  try waitForReport(0, value: 0x1234)
  try command(parent, .suspendThread(id: 1))
  #expect(originalBytes.pointee == 0)
  let denied = try parent.command(.snapshot(address: TaskGatePage.address, size: page)).get()
  #expect(denied.status == KERN_INVALID_ARGUMENT)
  #expect(denied.memoryEntry == nil)
  let snapshot = try parent.command(.snapshot(address: data, size: page)).get()
  try #require(snapshot.status == KERN_SUCCESS)
  let saved = try #require(snapshot.memoryEntry)
  defer { TaskMachMessage.releaseSend(saved) }
  try map(child, data, saved, rw, copy: true)
  try command(child, .createThread(id: 1, entry: code, argument: 0, stack: stack, tls: 0))
  try run(child, pc: code + 4, value: 0, reportSlot: 1)
  try waitForReport(1, value: 0x1234)
  try command(child, .suspendThread(id: 1))
  try run(parent, pc: code, value: 0xabcd, reportSlot: 2)
  try waitForReport(2, value: 0xabcd)
  try run(child, pc: code + 4, value: 0, reportSlot: 3)
  try waitForReport(3, value: 0x1234)
}

@Test func queriesDistinctStableKernelIdentitiesBeforeResumingThreads() throws {
  let task = try TaskSpawner.spawn(executable: builtExecutable("tarwin-task"))
  defer { terminateAndReap(task) }
  let start = TaskWindow.base
  let stack = start + TaskWindow.pageSize - 16
  #expect(throws: TaskTransportError.mach(KERN_INVALID_ARGUMENT)) {
    try task.threadIdentity(id: 1).get()
  }
  for id: UInt64 in [1, 2] {
    try #require(try task.command(
      .createThread(id: id, entry: start, argument: 0, stack: stack, tls: 0)).get().status == KERN_SUCCESS)
  }
  let first = try task.threadIdentity(id: 1).get()
  let second = try task.threadIdentity(id: 2).get()
  #expect(first != 0 && second != 0 && first != second)
  #expect(try task.threadIdentity(id: 1).get() == first)
  #expect(try task.threadIdentity(id: 2).get() == second)
}

@Test func liveMemoryTransfersHonorCopyOnWriteAndReturnRangeErrors() throws {
  let task = try TaskSpawner.spawn(executable: builtExecutable("tarwin-task"))
  defer { terminateAndReap(task) }
  let length = TaskMemoryTransfer.maximumSize
  let page = TaskWindow.pageSize
  let base = TaskWindow.base
  let snapshotBase = base + length + page
  let rw = VM_PROT_READ | VM_PROT_WRITE
  var backing: UInt64 = 0
  try #require(mach_vm_allocate(mach_task_self_, &backing, length, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
  defer { _ = mach_vm_deallocate(mach_task_self_, backing, length) }
  var original: mach_port_t = 0
  var entrySize = length
  try #require(mach_make_memory_entry_64(
    mach_task_self_, &entrySize, backing, rw, &original, 0) == KERN_SUCCESS)
  defer { TaskMachMessage.releaseSend(original) }
  try #require(try task.command(.map(TaskMapping(address: base, length: length, offset: 0,
    protection: UInt32(rw), copy: true)), memoryEntry: original).get().status == KERN_SUCCESS)

  func write(_ address: UInt64, _ bytes: [UInt8]) -> Result<Void, TaskTransportError> {
    bytes.withUnsafeBytes { task.writeMemory(address: address, data: $0) }
  }
  func read(_ address: UInt64, _ count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0xff, count: count)
    try bytes.withUnsafeMutableBytes { try task.readMemory(address: address, into: $0).get() }
    return bytes
  }
  let bulk = (0..<Int(length)).map { UInt8(truncatingIfNeeded: ($0 ^ ($0 >> 10)) * 13) }
  try write(base, bulk).get()
  #expect(try read(base, bulk.count) == bulk)
  let unaligned = base + page - 3
  let crossing = [UInt8](repeating: 0x6e, count: TaskMemoryTransfer.inlineLimit + 1)
  try write(unaligned, crossing).get()
  #expect(try read(unaligned, crossing.count) == crossing)
  let address = base + 7
  let first: [UInt8] = [42, 18, 7]
  let later: [UInt8] = [12, 13, 14]
  try write(address, first).get()
  #expect(try read(address, 3) == first)
  let snapshot = try task.command(.snapshot(address: base, size: page)).get()
  try #require(snapshot.status == KERN_SUCCESS)
  let saved = try #require(snapshot.memoryEntry)
  defer { TaskMachMessage.releaseSend(saved) }
  try write(address, later).get()
  #expect(try read(address, 3) == later)
  #expect(UnsafePointer<UInt8>(bitPattern: UInt(backing + 7))?.pointee == 0)
  try #require(try task.command(.map(TaskMapping(address: snapshotBase, length: page, offset: 0,
    protection: UInt32(rw), copy: true)), memoryEntry: saved).get().status == KERN_SUCCESS)
  #expect(try read(snapshotBase + 7, 3) == first)

  let outOfWindow = try task.command(.readMemory(address: base - 1, size: 1)).get()
  #expect(outOfWindow.status == KERN_INVALID_ARGUMENT)
  #expect(outOfWindow.data == nil)
  let gate = try task.command(.readMemory(address: TaskGatePage.address, size: 1)).get()
  #expect(gate.status == KERN_INVALID_ARGUMENT)
  #expect(throws: TaskTransportError.self) { try read(base + length - 1, 2) }
  #expect(throws: TaskTransportError.self) { try write(base + length, [1]).get() }
  #expect(throws: TaskTransportError.mach(KERN_INVALID_ARGUMENT)) { try read(base, Int(length) + 1) }
  try #require(try task.command(.protect(address: base, length: page,
    protection: UInt32(VM_PROT_READ))).get().status == KERN_SUCCESS)
  #expect(throws: TaskTransportError.self) { try write(address, first).get() }
  #expect(try read(address, 3) == later)
  try #require(try task.command(.protect(address: base, length: page,
    protection: UInt32(VM_PROT_NONE))).get().status == KERN_SUCCESS)
  #expect(throws: TaskTransportError.self) { try read(address, 3) }
  #expect(try read(snapshotBase + 7, 3) == first)
}

private func terminateAndReap(_ task: SpawnedTask) {
  if (try? task.command(.terminate, timeout: 1_000).get().status) != KERN_SUCCESS {
    kill(task.pid, SIGKILL)
  }
  while waitpid(task.pid, nil, 0) == -1 && errno == EINTR {}
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
