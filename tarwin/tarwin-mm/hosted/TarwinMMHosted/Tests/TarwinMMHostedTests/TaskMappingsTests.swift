import Darwin
import Dispatch
import Foundation
import TarwinMMHosted
import TarwinTaskProtocol
import TarwinTaskTransport
import Testing

private final class ProbeBundleAnchor {}

@Test func wireMapSendsANarrowedCapabilityAndPrivateCopy() throws {
  let page = hostedPageSize
  let entry = try HostedMemoryEntry.anonymous(size: 2 * page)
  let original = try entry.mapLocally(protection: [.read, .write])
  try [UInt8(21)].withUnsafeBytes { try original.write($0, offset: page) }
  let command = try HostedMapCommand(
    address: 4 * page, size: page, entryOffset: page, entry: entry,
    protection: [.read, .write], copy: true)
  let transport = HostedTaskCommandMappings { wire, right in
    let port = try #require(right)
    guard case .map(let mapping) = wire else {
      Issue.record("expected map")
      return TaskCommandReply(status: KERN_INVALID_ARGUMENT)
    }
    #expect(mapping.address == command.address)
    #expect(mapping.length == page)
    #expect(mapping.offset == 0)
    #expect(mapping.copy)
    let rw = VM_PROT_READ | VM_PROT_WRITE
    var address: UInt64 = 0
    let result = mach_vm_map(
      mach_task_self_, &address, page, 0, VM_FLAGS_ANYWHERE, port, 0, 0, rw, rw, VM_INHERIT_NONE)
    #expect(result == KERN_SUCCESS)
    guard result == KERN_SUCCESS else { return TaskCommandReply(status: result) }
    defer { mach_vm_deallocate(mach_task_self_, address, page) }
    let bytes = try #require(UnsafeMutablePointer<UInt8>(bitPattern: UInt(address)))
    #expect(bytes.pointee == 21)
    bytes.pointee = 99
    var outside: UInt64 = 0
    #expect(mach_vm_map(
      mach_task_self_, &outside, page, 0, VM_FLAGS_ANYWHERE, port, page, 0, rw, rw,
      VM_INHERIT_NONE) != KERN_SUCCESS)
    return TaskCommandReply(status: KERN_SUCCESS)
  }
  try transport.map(command)
  try transport.map(command)
  #expect(UnsafeRawPointer(bitPattern: UInt(original.address + page))!.load(as: UInt8.self) == 21)
}

@Test func sealedEntryMapsAndUnmapsThroughH2MachTransport() throws {
  let page = hostedPageSize
  var receive: mach_port_t = 0
  try #require(
    mach_port_allocate(mach_task_self_, UInt32(MACH_PORT_RIGHT_RECEIVE), &receive) == KERN_SUCCESS)
  let port = receive
  defer { mach_port_destroy(mach_task_self_, port) }
  try #require(
    mach_port_insert_right(mach_task_self_, port, port, UInt32(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
  var reserved: UInt64 = 0
  try #require(mach_vm_allocate(mach_task_self_, &reserved, page, VM_FLAGS_ANYWHERE) == KERN_SUCCESS)
  let address = reserved
  defer { mach_vm_deallocate(mach_task_self_, address, page) }

  let serverDone = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    defer { serverDone.signal() }
    for _ in 0..<2 {
      _ = TaskCommandTransport.serveOne(on: port, timeout: 2_000) { command, entry in
        switch command {
        case .map(let map):
          var target = map.address
          let protection = Int32(bitPattern: map.protection)
          return mach_vm_map(
            mach_task_self_, &target, map.length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
            entry, map.offset, map.copy ? 1 : 0, protection, protection, VM_INHERIT_NONE)
        case .unmap(let address, let size):
          return mach_vm_deallocate(mach_task_self_, address, size)
        default:
          return KERN_INVALID_ARGUMENT
        }
      }
    }
  }
  let task = HostedTaskCommandMappings { command, entry in
    try TaskCommandTransport.call(command, on: port, memoryEntry: entry ?? 0, timeout: 2_000).get()
  }
  defer { _ = serverDone.wait(timeout: .now() + .seconds(5)) }
  let space = try HostedAddressSpace(window: address..<(address + page), task: task)
  let code = try [UInt32(0x5280_0540), 0xd65f_03c0].withUnsafeBytes {
    try HostedMemoryEntry.sealedCode(size: page, verifiedBytes: $0)
  }
  try space.map(.init(address: address, size: page, entry: code, protection: [.read, .execute]))
  let fn = unsafeBitCast(UInt(address), to: (@convention(c) () -> UInt32).self)
  #expect(fn() == 42)
  #expect(mach_vm_protect(
    mach_task_self_, address, page, 0, VM_PROT_READ | VM_PROT_WRITE) == KERN_PROTECTION_FAILURE)
  try space.unmap(address: address, size: page)
  #expect(space.occupiedRanges.isEmpty)
}

@Test func twoSpawnedTasksExecuteTheSameSealedMemoryEntry() throws {
  let testBundle = Bundle(for: ProbeBundleAnchor.self).bundleURL
  let executable = testBundle.deletingLastPathComponent().appendingPathComponent("tarwin-task")
  let size = hostedPageSize
  let firstAddress = TaskWindow.base
  let secondAddress = firstAddress + 2 * size
  let first = try TaskSpawner.spawn(executable: executable.path)
  var firstReaped = false
  defer { if !firstReaped { kill(first.pid, SIGKILL); waitpid(first.pid, nil, 0) } }
  let second = try TaskSpawner.spawn(executable: executable.path)
  var secondReaped = false
  defer { if !secondReaped { kill(second.pid, SIGKILL); waitpid(second.pid, nil, 0) } }
  #expect(first.pid != second.pid)
  let code = try [UInt32(0x5280_0541), 0xb900_0001, 0x1400_0000].withUnsafeBytes {
    try HostedMemoryEntry.sealedCode(size: size, verifiedBytes: $0)
  }

  func execute(in task: SpawnedTask, at address: UInt64) throws {
    let transport = HostedTaskCommandMappings(task: task) { _ in kill(task.pid, SIGKILL) }
    let space = try HostedAddressSpace(
      window: TaskWindow.base..<(TaskWindow.base + TaskWindow.size), task: transport)
    try space.map(.init(address: address, size: size, entry: code, protection: [.read, .execute]))
    let rw = HostedProtection.read.union(.write)
    let writableCode = try task.command(.protect(
      address: address, length: size, protection: UInt32(rw.rawValue))).get()
    #expect(writableCode.status == KERN_PROTECTION_FAILURE)
    let data = address + size
    let stack = try HostedMemoryEntry.anonymous(size: size)
    let result = try stack.mapLocally(protection: .read)
    try space.map(.init(address: data, size: size, entry: stack, protection: rw))
    try #require(try task.command(.createThread(
      id: 1, entry: address, argument: data, stack: data + size - 16, tls: data)).get().status
      == KERN_SUCCESS)
    try #require(try task.command(.resumeThread(id: 1)).get().status == KERN_SUCCESS)
    let deadline = DispatchTime.now() + .seconds(5)
    var value: UInt32 = 0
    repeat {
      var bytesRead: UInt64 = 0
      let status = withUnsafeMutablePointer(to: &value) {
        mach_vm_read_overwrite(
          mach_task_self_, result.address, UInt64(MemoryLayout<UInt32>.size),
          UInt64(UInt(bitPattern: $0)), &bytesRead)
      }
      try #require(status == KERN_SUCCESS)
      if value != 0 { break }
      usleep(1_000)
    } while DispatchTime.now() < deadline
    try #require(value == 42)
  }
  try execute(in: first, at: firstAddress)
  try execute(in: second, at: secondAddress)
  func waitForExecution(_ task: SpawnedTask, reaped: inout Bool) throws {
    let reply = try task.command(.terminate).get()
    #expect(reply.status == KERN_SUCCESS)
    var status: Int32 = -1
    reaped = waitpid(task.pid, &status, 0) == task.pid
    #expect(reaped)
    #expect(status == 0)
  }
  try waitForExecution(first, reaped: &firstReaped)
  try waitForExecution(second, reaped: &secondReaped)
}

@Test func forkSnapshotsLivePrivateMemoryAndKeepsSealedCodeShared() throws {
  let testBundle = Bundle(for: ProbeBundleAnchor.self).bundleURL
  let executable = testBundle.deletingLastPathComponent().appendingPathComponent("tarwin-task")
  let parent = try TaskSpawner.spawn(executable: executable.path)
  defer { kill(parent.pid, SIGKILL); waitpid(parent.pid, nil, 0) }
  let child = try TaskSpawner.spawn(executable: executable.path)
  defer { kill(child.pid, SIGKILL); waitpid(child.pid, nil, 0) }

  let page = hostedPageSize
  let code = TaskWindow.base
  let data = code + page
  let reportAddress = data + page
  let stack = reportAddress + page - 16
  let source = try HostedMemoryEntry.anonymous(size: page)
  let original = try source.mapLocally(protection: .read)
  let report = try HostedMemoryEntry.anonymous(size: page)
  let observations = try report.mapLocally(protection: .read)
  let rx: HostedProtection = [.read, .execute]
  let rw: HostedProtection = [.read, .write]
  let instructions = try [UInt32(0xf900_0001), 0xf940_0002, 0xf900_0062, 0x1400_0000].withUnsafeBytes {
    try HostedMemoryEntry.sealedCode(size: page, verifiedBytes: $0)
  }
  func mappings(_ task: SpawnedTask) -> HostedTaskCommandMappings {
    HostedTaskCommandMappings(task: task) { _ in kill(task.pid, SIGKILL) }
  }
  let parentSpace = try HostedAddressSpace(
    window: TaskWindow.base..<(TaskWindow.base + TaskWindow.size), task: mappings(parent))
  try parentSpace.map(.init(address: code, size: page, entry: instructions, protection: rx), charged: false)
  try parentSpace.map(.init(address: data, size: page, entry: source, protection: rw, copy: true))
  try parentSpace.map(.init(address: reportAddress, size: page, entry: report, protection: rw))

  func send(_ command: TaskCommand, to task: SpawnedTask) throws {
    try #require(try task.command(command).get().status == KERN_SUCCESS)
  }
  func run(_ task: SpawnedTask, at pc: UInt64, write value: UInt64, slot: UInt64,
    expected: UInt64
  ) throws {
    var registers = InlineArray<31, UInt64>(repeating: 0)
    registers[0] = data
    registers[1] = value
    registers[3] = reportAddress + 8 * slot
    try send(.setThreadState(id: 1, state: TaskThreadState(
      registers: registers, stack: stack, pc: pc, cpsr: 0)), to: task)
    try send(.resumeThread(id: 1), to: task)
    let deadline = DispatchTime.now() + .seconds(5)
    var observed: UInt64 = 0
    repeat {
      var count: UInt64 = 0
      let status = withUnsafeMutablePointer(to: &observed) {
        mach_vm_read_overwrite(mach_task_self_, observations.address + 8 * slot, 8,
          UInt64(UInt(bitPattern: $0)), &count)
      }
      try #require(status == KERN_SUCCESS)
      if observed != 0 { break }
      usleep(1_000)
    } while DispatchTime.now() < deadline
    try #require(observed == expected)
    try send(.suspendThread(id: 1), to: task)
  }
  try send(.createThread(id: 1, entry: code, argument: 0, stack: stack, tls: 0), to: parent)
  try run(parent, at: code, write: 42, slot: 0, expected: 42)
  let childSpace = try parentSpace.fork(into: mappings(child))
  #expect(childSpace.footprint == 2 * page)
  #expect(childSpace.occupiedRanges.sorted { $0.lowerBound < $1.lowerBound }
    == parentSpace.occupiedRanges.sorted { $0.lowerBound < $1.lowerBound })
  let writeCode = try child.command(
    .protect(address: code, length: page, protection: UInt32(rw.rawValue))).get()
  #expect(writeCode.status == KERN_PROTECTION_FAILURE)

  try send(.createThread(id: 1, entry: code, argument: 0, stack: stack, tls: 0), to: child)
  try run(child, at: code + 4, write: 0, slot: 1, expected: 42)
  try run(parent, at: code, write: 51, slot: 2, expected: 51)
  try run(child, at: code + 4, write: 0, slot: 3, expected: 42)
  try run(child, at: code, write: 63, slot: 4, expected: 63)
  try run(parent, at: code + 4, write: 0, slot: 5, expected: 51)
  let originalBytes = try #require(UnsafeRawPointer(bitPattern: UInt(original.address)))
  #expect(originalBytes.load(as: UInt64.self) == 0)
}
