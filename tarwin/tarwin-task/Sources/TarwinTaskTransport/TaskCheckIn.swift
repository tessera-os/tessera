import Darwin
import TarwinTaskProtocol

public enum TaskCheckIn {
  public static let messageID: Int32 = 0x5457_0100
  public static let byteCount = 8

  /// On success, the caller owns the command receive and gate send rights.
  public static func send(
    bootstrap: mach_port_t, timeout: mach_msg_timeout_t = 5_000
  ) -> Result<TaskHostPorts, TaskTransportError> {
    var command: mach_port_t = 0
    var gate: mach_port_t = 0
    var status = TaskMachMessage.newReceive(&command)
    guard status == KERN_SUCCESS else { return .failure(.mach(status)) }
    status = TaskMachMessage.newReceive(&gate)
    guard status == KERN_SUCCESS else {
      TaskMachMessage.releaseReceive(command)
      return .failure(.mach(status))
    }
    status = mach_port_insert_right(mach_task_self_, gate, gate, UInt32(MACH_MSG_TYPE_MAKE_SEND))
    guard status == KERN_SUCCESS else {
      TaskMachMessage.releaseReceive(command)
      TaskMachMessage.releaseReceive(gate)
      return .failure(.mach(status))
    }
    status = TaskMachMessage.withPacket { packet in
      TaskMachMessage.prepare(
        packet, id: messageID, payloadBytes: byteCount, descriptors: 2,
        destination: bootstrap, disposition: MACH_MSG_TYPE_COPY_SEND)
      TaskMachMessage.putPort(packet, 0, command, MACH_MSG_TYPE_MAKE_SEND)
      TaskMachMessage.putPort(packet, 1, gate, MACH_MSG_TYPE_MOVE_RECEIVE)
      let offset = TaskMachMessage.payloadOffset(descriptors: 2)
      packet.storeBytes(of: TaskCommand.version.littleEndian, toByteOffset: offset, as: UInt32.self)
      packet.storeBytes(of: UInt32(0), toByteOffset: offset + 4, as: UInt32.self)
      return TaskMachMessage.send(packet, timeout: timeout)
    }
    guard status == KERN_SUCCESS else {
      TaskMachMessage.releaseSend(gate)
      TaskMachMessage.releaseReceive(gate)
      TaskMachMessage.releaseReceive(command)
      return .failure(.mach(status))
    }
    return .success(TaskHostPorts(commandReceive: command, gateSend: gate))
  }

  /// The bootstrap receive right is single-use and belongs to the spawner.
  static func receive(
    bootstrap: mach_port_t, pid: pid_t, timeout: mach_msg_timeout_t
  ) -> Result<KernelTaskPorts, TaskTransportError> {
    TaskMachMessage.withPacket { packet in
      let status = TaskMachMessage.receive(packet, on: bootstrap, timeout: timeout, audit: true)
      guard status == KERN_SUCCESS else { return .failure(.mach(status)) }
      guard let payload = TaskMachMessage.receivedPayload(packet, id: messageID, descriptors: 2),
        payload.count == byteCount, TaskMachMessage.auditPID(packet) == pid,
        UInt64(littleEndian: payload.loadUnaligned(as: UInt64.self)) == UInt64(TaskCommand.version),
        let command = TaskMachMessage.port(packet, 0, MACH_MSG_TYPE_PORT_SEND),
        let gate = TaskMachMessage.port(packet, 1, MACH_MSG_TYPE_PORT_RECEIVE)
      else {
        mach_msg_destroy(TaskMachMessage.header(packet))
        return .failure(.invalidMessage)
      }
      return .success(KernelTaskPorts(commandSend: command, gateReceive: gate))
    }
  }
}

public struct TaskHostPorts: Sendable {
  public let commandReceive: mach_port_t
  public let gateSend: mach_port_t
}

struct KernelTaskPorts: Sendable {
  let commandSend: mach_port_t
  let gateReceive: mach_port_t
}

public enum TaskTransportError: Error, Equatable {
  case mach(mach_msg_return_t)
  case spawn(Int32)
  case childExited(Int32)
  case invalidMessage
}
