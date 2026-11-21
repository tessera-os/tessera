import Darwin

enum TaskMachMessage {
  static let headerBytes = MemoryLayout<mach_msg_header_t>.size
  static let bodyBytes = MemoryLayout<mach_msg_body_t>.size
  static let descriptorBytes = MemoryLayout<mach_msg_port_descriptor_t>.size
  static let invalid = KERN_INVALID_ARGUMENT

  static func withPacket<T>(_ body: (UnsafeMutableRawBufferPointer) -> T) -> T {
    var storage = InlineArray<64, UInt64>(repeating: 0)
    return withUnsafeMutableBytes(of: &storage, body)
  }

  static func header(_ packet: UnsafeMutableRawBufferPointer) -> UnsafeMutablePointer<mach_msg_header_t> {
    packet.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self)
  }

  static func payloadOffset(descriptors: Int) -> Int {
    headerBytes + (descriptors == 0 ? 0 : bodyBytes + descriptors * descriptorBytes)
  }

  static func prepare(
    _ packet: UnsafeMutableRawBufferPointer, id: Int32, payloadBytes: Int, descriptors: Int = 0,
    destination: mach_port_t, disposition: Int32, reply: mach_port_t = 0
  ) {
    var bits = UInt32(disposition)
    if reply != 0 { bits |= UInt32(MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8 }
    if descriptors != 0 { bits |= MACH_MSGH_BITS_COMPLEX }
    header(packet).pointee = mach_msg_header_t(
      msgh_bits: bits, msgh_size: UInt32(payloadOffset(descriptors: descriptors) + payloadBytes),
      msgh_remote_port: destination, msgh_local_port: reply, msgh_voucher_port: 0, msgh_id: id)
    if descriptors != 0 {
      packet.storeBytes(of: UInt32(descriptors), toByteOffset: headerBytes, as: UInt32.self)
    }
  }

  static func putPort(
    _ packet: UnsafeMutableRawBufferPointer, _ index: Int, _ name: mach_port_t, _ disposition: Int32
  ) {
    let port = mach_msg_port_descriptor_t(
      name: name, pad1: 0, pad2: 0,
      disposition: UInt32(disposition), type: UInt32(MACH_MSG_PORT_DESCRIPTOR))
    packet.storeBytes(of: port, toByteOffset: headerBytes + bodyBytes + index * descriptorBytes,
      as: mach_msg_port_descriptor_t.self)
  }

  static func port(
    _ packet: UnsafeMutableRawBufferPointer, _ index: Int, _ disposition: Int32
  ) -> mach_port_t? {
    let offset = headerBytes + bodyBytes + index * descriptorBytes
    let descriptor = UnsafeRawBufferPointer(packet).loadUnaligned(
      fromByteOffset: offset, as: mach_msg_port_descriptor_t.self)
    guard descriptor.type == UInt8(MACH_MSG_PORT_DESCRIPTOR),
      descriptor.disposition == UInt8(disposition), descriptor.name != 0,
      descriptor.name != mach_port_t.max
    else { return nil }
    return descriptor.name
  }

  static func receivedPayload(
    _ packet: UnsafeMutableRawBufferPointer, id: Int32, descriptors: Int = 0,
    replyDisposition: UInt32 = 0
  ) -> UnsafeRawBufferPointer? {
    let message = header(packet).pointee
    let offset = payloadOffset(descriptors: descriptors)
    guard message.msgh_id == id, message.msgh_size >= offset, message.msgh_size <= packet.count,
      (message.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0) == (descriptors != 0),
      message.msgh_bits & 0x1f == replyDisposition, message.msgh_voucher_port == 0,
      (message.msgh_remote_port == 0) == (replyDisposition == 0),
      message.msgh_remote_port != mach_port_t.max
    else { return nil }
    if descriptors != 0 {
      guard UnsafeRawBufferPointer(packet).loadUnaligned(
        fromByteOffset: headerBytes, as: UInt32.self) == descriptors
      else { return nil }
    }
    return UnsafeRawBufferPointer(rebasing: packet[offset..<Int(message.msgh_size)])
  }

  static func send(
    _ packet: UnsafeMutableRawBufferPointer, timeout: mach_msg_timeout_t
  ) -> mach_msg_return_t {
    let head = header(packet)
    return mach_msg(head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, head.pointee.msgh_size, 0, 0, timeout, 0)
  }

  static func receive(
    _ packet: UnsafeMutableRawBufferPointer, on port: mach_port_t,
    timeout: mach_msg_timeout_t?, audit: Bool = false
  ) -> mach_msg_return_t {
    var options = MACH_RCV_MSG
    if timeout != nil { options |= MACH_RCV_TIMEOUT }
    if audit { options |= Int32(MACH_RCV_TRAILER_AUDIT) << 24 }
    return mach_msg(header(packet), options, 0, UInt32(packet.count), port, timeout ?? 0, 0)
  }

  static func auditPID(_ packet: UnsafeMutableRawBufferPointer) -> pid_t? {
    let size = Int(header(packet).pointee.msgh_size)
    let offset = (size + 3) & ~3
    guard offset + MemoryLayout<mach_msg_audit_trailer_t>.size <= packet.count else { return nil }
    let trailer = UnsafeRawBufferPointer(packet).loadUnaligned(
      fromByteOffset: offset, as: mach_msg_audit_trailer_t.self)
    guard trailer.msgh_trailer_type == MACH_MSG_TRAILER_FORMAT_0,
      trailer.msgh_trailer_size >= MemoryLayout<mach_msg_audit_trailer_t>.size else { return nil }
    return pid_t(bitPattern: trailer.msgh_audit.val.5)
  }

  static func newReceive(_ port: inout mach_port_t) -> kern_return_t {
    mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
  }
  static func releaseSend(_ port: mach_port_t) {
    _ = mach_port_deallocate(mach_task_self_, port)
  }
  static func releaseReceive(_ port: mach_port_t) {
    _ = mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
  }
}
