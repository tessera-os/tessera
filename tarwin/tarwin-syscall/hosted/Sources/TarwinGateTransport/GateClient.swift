import Darwin
import TarwinHostedGate

public enum GateClient {
  /// Uses the calling thread's exclusive receive port and a stack buffer.
  /// A timed-out call invalidates that receive port for subsequent calls.
  public static func call(
    _ request: GateRequest, on gate: mach_port_t, replyPort: mach_port_t,
    timeout: mach_msg_timeout_t? = nil
  ) -> Result<GateReply, GateTransportError> {
    GateMachPacket.withPacket { bytes in
      GateMachPacket.prepare(
        bytes, id: GateRequest.messageID, size: GateRequest.byteCount,
        destination: gate, disposition: MACH_MSG_TYPE_COPY_SEND, reply: replyPort)
      _ = request.encode(into: GateMachPacket.payload(bytes, size: GateRequest.byteCount))
      let header = GateMachPacket.header(bytes)
      var options = MACH_SEND_MSG | MACH_RCV_MSG
      if timeout != nil { options |= MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT }
      let result = mach_msg(
        header, options, header.pointee.msgh_size, UInt32(bytes.count), replyPort, timeout ?? 0, 0)
      guard result == KERN_SUCCESS else { return .failure(.mach(result)) }
      guard GateMachPacket.matches(
        header.pointee, id: GateReply.messageID, size: GateReply.byteCount, replyDisposition: 0),
        let reply = GateReply(decoding: UnsafeRawBufferPointer(
          GateMachPacket.payload(bytes, size: GateReply.byteCount)))
      else {
        mach_msg_destroy(header)
        return .failure(.invalidMessage)
      }
      return .success(reply)
    }
  }
}
