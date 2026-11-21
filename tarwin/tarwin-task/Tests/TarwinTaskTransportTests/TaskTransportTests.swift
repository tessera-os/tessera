import Darwin
import Dispatch
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
