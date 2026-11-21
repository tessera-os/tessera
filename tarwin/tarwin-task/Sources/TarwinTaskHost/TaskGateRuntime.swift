import CTarwinTaskGate
import Darwin
import TarwinGateTransport
import TarwinTaskProtocol

struct TaskGateRuntime {
  private static let gateRightWord = 2
  private static let slotsWord = 4
  private static let wordsPerSlot = 4
  private let writable: UnsafeMutablePointer<UInt64>

  static func install(gate: mach_port_t) -> Self? {
    var size = TaskWindow.pageSize
    var entry: mach_port_t = 0
    guard mach_make_memory_entry_64(
      mach_task_self_, &size, 0, MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE, &entry, 0)
      == KERN_SUCCESS else { return nil }
    defer { _ = mach_port_deallocate(mach_task_self_, entry) }
    var writeAddress: mach_vm_address_t = 0
    let readWrite = VM_PROT_READ | VM_PROT_WRITE
    guard mach_vm_map(
      mach_task_self_, &writeAddress, size, 0, VM_FLAGS_ANYWHERE, entry, 0, 0,
      readWrite, readWrite, VM_INHERIT_NONE) == KERN_SUCCESS else { return nil }
    var readAddress = TaskGatePage.address
    guard mach_vm_map(
      mach_task_self_, &readAddress, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, entry, 0, 0,
      VM_PROT_READ, VM_PROT_READ, VM_INHERIT_NONE) == KERN_SUCCESS else {
      _ = mach_vm_deallocate(mach_task_self_, writeAddress, size)
      return nil
    }
    let words = UnsafeMutablePointer<UInt64>(bitPattern: UInt(writeAddress))!
    words[TaskGatePage.gateEntryOffset / 8] =
      unsafeBitCast(tarwin_task_gate_entry as @convention(c) () -> Void, to: UInt64.self)
    words[TaskGatePage.tlsEntryOffset / 8] =
      unsafeBitCast(tarwin_task_tls_entry as @convention(c) () -> Void, to: UInt64.self)
    words[gateRightWord] = UInt64(gate)
    return Self(writable: words)
  }

  func register(index: Int, thread: mach_port_t, id: UInt64, tls: UInt64, reply: mach_port_t) {
    let slot = writable + (Self.slotsWord + index * Self.wordsPerSlot)
    slot[1] = id
    slot[2] = tls
    slot[3] = UInt64(reply)
    slot[0] = UInt64(thread)
  }

  fileprivate static func current() -> (id: UInt64, tls: UInt64, gate: mach_port_t, reply: mach_port_t)? {
    let thread = mach_thread_self()
    guard thread != 0 else { return nil }
    defer { _ = mach_port_deallocate(mach_task_self_, thread) }
    let page = UnsafePointer<UInt64>(bitPattern: UInt(TaskGatePage.address))!
    for i in 0..<TaskGatePage.maxThreads {
      let slot = page + (slotsWord + i * wordsPerSlot)
      if slot[0] == UInt64(thread) {
        return (slot[1], slot[2], mach_port_t(truncatingIfNeeded: page[gateRightWord]),
          mach_port_t(truncatingIfNeeded: slot[3]))
      }
    }
    return nil
  }
}

@_cdecl("tarwin_task_gate_bridge")
func taskGateBridge(_ frame: UnsafeMutablePointer<UInt64>) -> kern_return_t {
  guard let slot = TaskGateRuntime.current() else { return KERN_INVALID_ARGUMENT }
  return tarwinHostedGateCall(frame, slot.id, slot.gate, slot.reply)
}

@_cdecl("tarwin_task_tls_bridge")
func taskTLSBridge() -> UInt64 {
  TaskGateRuntime.current()?.tls ?? 0
}
