import Darwin
import TarwinTaskProtocol

extension SpawnedTask {
  public func readMemory(
    address: UInt64, into buffer: UnsafeMutableRawBufferPointer, timeout: mach_msg_timeout_t = 5_000
  ) -> Result<Void, TaskTransportError> {
    let size = UInt64(buffer.count)
    guard TaskMemoryTransfer.contains(address: address, size: size) else {
      return .failure(.mach(KERN_INVALID_ARGUMENT))
    }
    let request = TaskCommand.readMemory(address: address, size: size)
    if buffer.count <= TaskMemoryTransfer.inlineLimit {
      return command(request, timeout: timeout).flatMap { reply in
        guard reply.status == KERN_SUCCESS else { return .failure(.mach(reply.status)) }
        guard let data = reply.data else { return .failure(.invalidMessage) }
        data.withBytes { buffer.copyBytes(from: $0) }
        return .success(())
      }
    }
    return Self.withStagingBuffer(size: size) { staging, entry in
      command(request, memoryEntry: entry, timeout: timeout).flatMap { reply in
        guard reply.status == KERN_SUCCESS else { return .failure(.mach(reply.status)) }
        buffer.copyBytes(from: UnsafeRawBufferPointer(staging))
        return .success(())
      }
    }
  }

  public func writeMemory(
    address: UInt64, data: UnsafeRawBufferPointer, timeout: mach_msg_timeout_t = 5_000
  ) -> Result<Void, TaskTransportError> {
    let size = UInt64(data.count)
    guard TaskMemoryTransfer.contains(address: address, size: size) else {
      return .failure(.mach(KERN_INVALID_ARGUMENT))
    }
    if let inline = TaskMemoryBytes(data) {
      return command(.writeMemory(address: address, data: .inline(inline)), timeout: timeout)
        .flatMap(Self.checkStatus)
    }
    return Self.withStagingBuffer(size: size) { staging, entry in
      staging.copyBytes(from: data)
      return command(.writeMemory(address: address, data: .staged(size: size)),
        memoryEntry: entry, timeout: timeout).flatMap(Self.checkStatus)
    }
  }

  private static func checkStatus(_ reply: TaskCommandReply) -> Result<Void, TaskTransportError> {
    reply.status == KERN_SUCCESS ? .success(()) : .failure(.mach(reply.status))
  }

  private static func withStagingBuffer(
    size: UInt64,
    _ body: (UnsafeMutableRawBufferPointer, mach_port_t) -> Result<Void, TaskTransportError>
  ) -> Result<Void, TaskTransportError> {
    var address: UInt64 = 0
    let length = (size + TaskWindow.pageSize - 1) & ~(TaskWindow.pageSize - 1)
    let allocation = mach_vm_allocate(mach_task_self_, &address, length, VM_FLAGS_ANYWHERE)
    guard allocation == KERN_SUCCESS else { return .failure(.mach(allocation)) }
    defer { _ = mach_vm_deallocate(mach_task_self_, address, length) }
    var entry: mach_port_t = 0
    var entrySize = length
    let status = mach_make_memory_entry_64(mach_task_self_, &entrySize, address,
      VM_PROT_READ | VM_PROT_WRITE, &entry, 0)
    guard status == KERN_SUCCESS else { return .failure(.mach(status)) }
    guard entry != 0 else { return .failure(.mach(KERN_FAILURE)) }
    defer { TaskMachMessage.releaseSend(entry) }
    guard entrySize == length else { return .failure(.mach(KERN_FAILURE)) }
    let buffer = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(address)),
      count: Int(size))
    return body(buffer, entry)
  }
}
