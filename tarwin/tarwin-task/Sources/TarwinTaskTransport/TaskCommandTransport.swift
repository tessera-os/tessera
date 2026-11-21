import Darwin
import TarwinTaskProtocol

public enum TaskCommandTransport {
  public static func call(
    _ command: TaskCommand, on port: mach_port_t, memoryEntry: mach_port_t = 0,
    timeout: mach_msg_timeout_t = 5_000
  ) -> Result<TaskCommandReply, TaskTransportError> {
    let ports = command.opcode.carriesMemoryEntry ? 1 : 0
    guard (ports == 1) == (memoryEntry != 0) else { return .failure(.invalidMessage) }
    var reply: mach_port_t = 0
    let allocated = TaskMachMessage.newReceive(&reply)
    guard allocated == KERN_SUCCESS else { return .failure(.mach(allocated)) }
    defer { TaskMachMessage.releaseReceive(reply) }
    return TaskMachMessage.withPacket { packet in
      TaskMachMessage.prepare(
        packet, id: TaskCommand.messageID, payloadBytes: command.opcode.byteCount,
        descriptors: ports, destination: port, disposition: MACH_MSG_TYPE_COPY_SEND, reply: reply)
      if ports != 0 { TaskMachMessage.putPort(packet, 0, memoryEntry, MACH_MSG_TYPE_COPY_SEND) }
      let offset = TaskMachMessage.payloadOffset(descriptors: ports)
      guard command.encode(into: UnsafeMutableRawBufferPointer(
        rebasing: packet[offset..<(offset + command.opcode.byteCount)]))
      else { return .failure(.invalidMessage) }
      let head = TaskMachMessage.header(packet)
      let status = mach_msg(
        head, MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
        head.pointee.msgh_size, UInt32(packet.count), reply, timeout, 0)
      guard status == KERN_SUCCESS else { return .failure(.mach(status)) }
      guard let bytes = TaskMachMessage.receivedPayload(packet, id: TaskCommandReply.messageID),
        let reply = TaskCommandReply(decoding: bytes)
      else {
        mach_msg_destroy(head)
        return .failure(.invalidMessage)
      }
      return .success(reply)
    }
  }

  /// The memory entry is borrowed during the handler. The reply right is
  /// consumed before returning. A rejected message never invokes the handler.
  public static func serveOne(
    on port: mach_port_t, timeout: mach_msg_timeout_t? = nil,
    _ handle: (TaskCommand, mach_port_t) -> kern_return_t
  ) -> Result<TaskCommand.Opcode, TaskTransportError> {
    TaskMachMessage.withPacket { packet in
      let status = TaskMachMessage.receive(packet, on: port, timeout: timeout)
      guard status == KERN_SUCCESS else { return .failure(.mach(status)) }
      let head = TaskMachMessage.header(packet)
      let ports = head.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0 ? 1 : 0
      guard let bytes = TaskMachMessage.receivedPayload(
        packet, id: TaskCommand.messageID, descriptors: ports,
        replyDisposition: UInt32(MACH_MSG_TYPE_PORT_SEND_ONCE)),
        let command = TaskCommand(decoding: bytes),
        command.opcode.carriesMemoryEntry == (ports == 1),
        let entry = ports == 0 ? mach_port_t(0) : TaskMachMessage.port(packet, 0, MACH_MSG_TYPE_PORT_SEND)
      else {
        mach_msg_destroy(head)
        return .failure(.invalidMessage)
      }
      let reply = head.pointee.msgh_remote_port
      let result = handle(command, entry)
      if entry != 0 { TaskMachMessage.releaseSend(entry) }
      TaskMachMessage.prepare(
        packet, id: TaskCommandReply.messageID, payloadBytes: TaskCommandReply.byteCount,
        destination: reply, disposition: MACH_MSG_TYPE_MOVE_SEND_ONCE)
      let offset = TaskMachMessage.headerBytes
      _ = TaskCommandReply(status: result).encode(into: UnsafeMutableRawBufferPointer(
        rebasing: packet[offset..<(offset + TaskCommandReply.byteCount)]))
      if TaskMachMessage.send(packet, timeout: timeout ?? 5_000) != KERN_SUCCESS {
        TaskMachMessage.releaseSend(reply)
      }
      return .success(command.opcode)
    }
  }
}
