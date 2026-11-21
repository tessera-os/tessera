import Darwin
import Synchronization
import TarwinHostedGate

/// A kernel worker can return after passing this object into a wait record.
/// A completed or abandoned wait consumes its owned send-once right.
public final class PendingGateReply: Sendable {
  private let port: Mutex<mach_port_t>
  fileprivate init(_ port: mach_port_t) { self.port = Mutex(port) }

  public func send(_ reply: GateReply) -> Result<Void, GateTransportError> {
    let right = take()
    guard right != 0 else { return .failure(.spentReply) }
    let status = GateMachPacket.withPacket { bytes in
      GateMachPacket.prepare(
        bytes, id: GateReply.messageID, size: GateReply.byteCount,
        destination: right, disposition: MACH_MSG_TYPE_MOVE_SEND_ONCE)
      _ = reply.encode(into: GateMachPacket.payload(bytes, size: GateReply.byteCount))
      let header = GateMachPacket.header(bytes)
      return mach_msg(header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, header.pointee.msgh_size, 0, 0, 0, 0)
    }
    if status != KERN_SUCCESS {
      _ = mach_port_deallocate(mach_task_self_, right)
      return .failure(.mach(status))
    }
    return .success(())
  }

  public func cancel() {
    let right = take()
    if right != 0 { _ = mach_port_deallocate(mach_task_self_, right) }
  }

  deinit { cancel() }

  private func take() -> mach_port_t {
    port.withLock { name in
      let old = name
      name = 0
      return old
    }
  }
}

public struct ReceivedGateCall {
  public let gatePort: mach_port_t
  public let senderPID: pid_t
  public let request: GateRequest
  public let reply: PendingGateReply
}

public final class GatePortSet: Sendable {
  private let port: mach_port_t

  public init() throws {
    var name: mach_port_t = 0
    let result = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_PORT_SET, &name)
    guard result == KERN_SUCCESS else { throw GateTransportError.mach(result) }
    port = name
  }

  deinit { _ = mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_PORT_SET, -1) }

  /// The caller retains the member's receive right.
  public func insert(_ gateReceive: mach_port_t) -> kern_return_t {
    mach_port_move_member(mach_task_self_, gateReceive, port)
  }

  public func remove(_ gateReceive: mach_port_t) -> kern_return_t {
    mach_port_move_member(mach_task_self_, gateReceive, 0)
  }

  public func receive(timeout: mach_msg_timeout_t? = nil) -> Result<ReceivedGateCall, GateTransportError> {
    GateMachPacket.withPacket { bytes in
      let head = GateMachPacket.header(bytes)
      var options = MACH_RCV_MSG | (Int32(MACH_RCV_TRAILER_AUDIT) << 24)
      if timeout != nil { options |= MACH_RCV_TIMEOUT }
      let status = mach_msg(head, options, 0, UInt32(bytes.count), port, timeout ?? 0, 0)
      guard status == KERN_SUCCESS else { return .failure(.mach(status)) }
      let message = head.pointee
      guard GateMachPacket.matches(
        message, id: GateRequest.messageID, size: GateRequest.byteCount,
        replyDisposition: UInt32(MACH_MSG_TYPE_PORT_SEND_ONCE)),
        let request = GateRequest(decoding: UnsafeRawBufferPointer(
          GateMachPacket.payload(bytes, size: GateRequest.byteCount)))
      else {
        mach_msg_destroy(head)
        return .failure(.invalidMessage)
      }
      let trailer = UnsafeRawBufferPointer(bytes).loadUnaligned(
        fromByteOffset: GateMachPacket.headerSize + GateRequest.byteCount,
        as: mach_msg_audit_trailer_t.self)
      guard trailer.msgh_trailer_type == MACH_MSG_TRAILER_FORMAT_0,
        trailer.msgh_trailer_size >= MemoryLayout<mach_msg_audit_trailer_t>.size
      else {
        mach_msg_destroy(head)
        return .failure(.invalidMessage)
      }
      return .success(ReceivedGateCall(
        gatePort: message.msgh_local_port, senderPID: pid_t(bitPattern: trailer.msgh_audit.val.5),
        request: request, reply: PendingGateReply(message.msgh_remote_port)))
    }
  }
}
