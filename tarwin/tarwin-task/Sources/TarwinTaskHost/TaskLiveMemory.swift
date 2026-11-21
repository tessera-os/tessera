import Darwin
import TarwinTaskProtocol

enum TaskLiveMemory {
  static func read(address: UInt64, size: UInt64, entry: mach_port_t) -> TaskCommandReply {
    guard TaskMemoryTransfer.contains(address: address, size: size) else {
      return TaskCommandReply(status: KERN_INVALID_ARGUMENT)
    }
    if size <= TaskMemoryTransfer.inlineLimit {
      var storage = InlineArray<256, UInt8>(repeating: 0)
      return withUnsafeMutableBytes(of: &storage) { buffer in
        let status = copyOut(address: address, size: size, to: UInt64(UInt(bitPattern: buffer.baseAddress)))
        guard status == KERN_SUCCESS else { return TaskCommandReply(status: status) }
        return TaskCommandReply(status: status, data: TaskMemoryBytes(
          UnsafeRawBufferPointer(rebasing: buffer.prefix(Int(size)))))
      }
    }
    return TaskCommandReply(status: withStagingEntry(entry, size: size, protection: VM_PROT_READ | VM_PROT_WRITE) {
      copyOut(address: address, size: size, to: $0)
    })
  }

  static func write(address: UInt64, data: TaskMemoryWrite, entry: mach_port_t) -> TaskCommandReply {
    switch data {
    case .inline(let data):
      let size = UInt64(data.count)
      guard TaskMemoryTransfer.contains(address: address, size: size) else {
        return TaskCommandReply(status: KERN_INVALID_ARGUMENT)
      }
      return TaskCommandReply(status: data.withBytes {
        copyIn(address: address, size: size, from: UInt64(UInt(bitPattern: $0.baseAddress)))
      })
    case .staged(let size):
      guard TaskMemoryTransfer.contains(address: address, size: size) else {
        return TaskCommandReply(status: KERN_INVALID_ARGUMENT)
      }
      return TaskCommandReply(status: withStagingEntry(entry, size: size, protection: VM_PROT_READ) {
        copyIn(address: address, size: size, from: $0)
      })
    }
  }

  private static func copyOut(address: UInt64, size: UInt64, to destination: UInt64) -> kern_return_t {
    var copied: UInt64 = 0
    let status = mach_vm_read_overwrite(mach_task_self_, address, size, destination, &copied)
    return status == KERN_SUCCESS && copied != size ? KERN_FAILURE : status
  }

  private static func copyIn(address: UInt64, size: UInt64, from source: UInt64) -> kern_return_t {
    mach_vm_write(mach_task_self_, address, vm_offset_t(source), mach_msg_type_number_t(size))
  }

  private static func withStagingEntry(
    _ entry: mach_port_t, size: UInt64, protection: vm_prot_t, _ body: (UInt64) -> kern_return_t
  ) -> kern_return_t {
    var address: UInt64 = 0
    let length = (size + TaskWindow.pageSize - 1) & ~(TaskWindow.pageSize - 1)
    let status = mach_vm_map(mach_task_self_, &address, length, 0, VM_FLAGS_ANYWHERE, entry, 0, 0,
      protection, protection, VM_INHERIT_NONE)
    guard status == KERN_SUCCESS else { return status }
    defer { _ = mach_vm_deallocate(mach_task_self_, address, length) }
    return body(address)
  }
}
