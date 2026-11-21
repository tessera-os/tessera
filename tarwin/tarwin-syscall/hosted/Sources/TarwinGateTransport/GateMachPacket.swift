import Darwin
import TarwinHostedGate

enum GateMachPacket {
  static let headerSize = MemoryLayout<mach_msg_header_t>.size

  static func withPacket<T>(_ body: (UnsafeMutableRawBufferPointer) -> T) -> T {
    var storage = InlineArray<24, UInt64>(repeating: 0)
    return withUnsafeMutableBytes(of: &storage, body)
  }

  static func header(_ bytes: UnsafeMutableRawBufferPointer) -> UnsafeMutablePointer<mach_msg_header_t> {
    bytes.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self)
  }

  static func payload(
    _ bytes: UnsafeMutableRawBufferPointer, size: Int
  ) -> UnsafeMutableRawBufferPointer {
    UnsafeMutableRawBufferPointer(rebasing: bytes[headerSize..<(headerSize + size)])
  }

  static func prepare(
    _ bytes: UnsafeMutableRawBufferPointer, id: Int32, size: Int, destination: mach_port_t,
    disposition: Int32, reply: mach_port_t = 0
  ) {
    let local = reply != 0 ? UInt32(MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8 : 0
    header(bytes).pointee = mach_msg_header_t(
      msgh_bits: UInt32(disposition) | local,
      msgh_size: UInt32(headerSize + size), msgh_remote_port: destination,
      msgh_local_port: reply, msgh_voucher_port: 0, msgh_id: id)
  }

  static func matches(
    _ message: mach_msg_header_t, id: Int32, size: Int, replyDisposition: UInt32
  ) -> Bool {
    message.msgh_id == id && message.msgh_size == headerSize + size
      && message.msgh_bits & MACH_MSGH_BITS_COMPLEX == 0
      && message.msgh_bits & 0x1f == replyDisposition && message.msgh_voucher_port == 0
      && (message.msgh_remote_port == 0) == (replyDisposition == 0)
      && message.msgh_remote_port != mach_port_t.max
  }
}

public enum GateTransportError: Error, Equatable {
  case mach(mach_msg_return_t)
  case invalidMessage
  case spentReply
}
