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
      let descriptors = command.opcode == .snapshot && head.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0
        ? 1 : 0
      guard let bytes = TaskMachMessage.receivedPayload(
        packet, id: TaskCommandReply.messageID, descriptors: descriptors),
        let reply = TaskCommandReply(decoding: bytes),
        (command.opcode == .snapshot && reply.status == KERN_SUCCESS) == (descriptors == 1),
        (command.opcode == .threadIdentity && reply.status == KERN_SUCCESS) == (reply.kernelThreadID != nil)
      else {
        mach_msg_destroy(head)
        return .failure(.invalidMessage)
      }
      if descriptors == 0 { return .success(reply) }
      guard let entry = TaskMachMessage.port(packet, 0, MACH_MSG_TYPE_PORT_SEND) else {
        mach_msg_destroy(head)
        return .failure(.invalidMessage)
      }
      return .success(TaskCommandReply(status: reply.status, memoryEntry: entry))
    }
  }

  /// The memory entry is borrowed during the handler. The reply right is
  /// consumed before returning. A rejected message never invokes the handler.
  public static func serveOne(
    on port: mach_port_t, timeout: mach_msg_timeout_t? = nil,
    _ handle: (TaskCommand, mach_port_t) -> kern_return_t
  ) -> Result<TaskCommand.Opcode, TaskTransportError> {
    serveOneReply(on: port, timeout: timeout) { command, entry in
      TaskCommandReply(status: handle(command, entry))
    }
  }

  /// As with serveOne, the incoming entry is borrowed; an outgoing entry is consumed.
  public static func serveOneReply(
    on port: mach_port_t, timeout: mach_msg_timeout_t? = nil,
    _ handle: (TaskCommand, mach_port_t) -> TaskCommandReply
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
      var result = handle(command, entry)
      if entry != 0 { TaskMachMessage.releaseSend(entry) }
      let expectedEntry = command.opcode == .snapshot && result.status == KERN_SUCCESS
      let expectedThreadID = command.opcode == .threadIdentity && result.status == KERN_SUCCESS
      if expectedEntry != (result.memoryEntry != nil)
        || expectedThreadID != (result.kernelThreadID != nil) || result.kernelThreadID == 0 {
        if let unexpected = result.memoryEntry { TaskMachMessage.releaseSend(unexpected) }
        result = TaskCommandReply(status: KERN_FAILURE)
      }
      let descriptors = result.memoryEntry == nil ? 0 : 1
      TaskMachMessage.prepare(
        packet, id: TaskCommandReply.messageID, payloadBytes: result.payloadByteCount,
        descriptors: descriptors, destination: reply, disposition: MACH_MSG_TYPE_MOVE_SEND_ONCE)
      if let output = result.memoryEntry {
        TaskMachMessage.putPort(packet, 0, output, MACH_MSG_TYPE_COPY_SEND)
      }
      let offset = TaskMachMessage.payloadOffset(descriptors: descriptors)
      _ = result.encode(into: UnsafeMutableRawBufferPointer(
        rebasing: packet[offset..<(offset + result.payloadByteCount)]))
      if TaskMachMessage.send(packet, timeout: timeout ?? 5_000) != KERN_SUCCESS {
        TaskMachMessage.releaseSend(reply)
      }
      if let output = result.memoryEntry { TaskMachMessage.releaseSend(output) }
      return .success(command.opcode)
    }
  }
}
