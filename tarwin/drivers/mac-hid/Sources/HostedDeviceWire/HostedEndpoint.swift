import Darwin
import Dispatch
import TarwinArchHosted

private final class ReceiveRight: @unchecked Sendable {
  let port: HostPort
  init() throws { port = try HostPort.receive() }
}

/// A bounded inline Mach inbox for TWHD frames. The source owns the receive right
/// through cancellation; each open returns a separately owned send reference.
public final class HostedDriverEndpoint: @unchecked Sendable {
  private let right: ReceiveRight
  private let source: any DispatchSourceMachReceive
  private let buffer: UnsafeMutableRawPointer
  private let handler: (UnsafeRawBufferPointer) -> Void
  private static let bufferSize = 66_112
  private static let messageID: Int32 = 0x54574844
  public init(handler: @escaping (UnsafeRawBufferPointer) -> Void) throws {
    let right = try ReceiveRight()
    self.right = right; self.handler = handler
    buffer = .allocate(byteCount: Self.bufferSize, alignment: 8)
    let source = DispatchSource.makeMachReceiveSource(port: right.port.rawName,
      queue: DispatchQueue(label: "tarwin.device.inbox", qos: .userInteractive))
    self.source = source
    source.setCancelHandler { withExtendedLifetime(right) {} }
    source.setEventHandler { [weak self] in self?.drain() }
    source.resume()
  }
  deinit { source.cancel(); buffer.deallocate() }
  public func open(slot: UInt32) throws -> HostPort {
    guard slot == 0 else { throw HostError("device slot", code: KERN_INVALID_ARGUMENT) }
    return try right.port.makeSend()
  }
  /// Inline message = Mach header, u32 frame length, frame, zero padding to 4 bytes.
  public static func send(frame: UnsafeRawBufferPointer, to port: borrowing HostPort) throws {
    guard port.kind == .send, FrameView(frame) != nil else { throw HostError("device frame", code: KERN_INVALID_ARGUMENT) }
    let headerSize = MemoryLayout<mach_msg_header_t>.size
    let size = (headerSize + 4 + frame.count + 3) & ~3
    try withUnsafeTemporaryAllocation(of: UInt64.self, capacity: (size + 7) / 8) { storage in
      storage.initialize(repeating: 0)
      let raw = UnsafeMutableRawBufferPointer(storage)
      let header = raw.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self)
      header.pointee = mach_msg_header_t(msgh_bits: mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND),
        msgh_size: UInt32(size), msgh_remote_port: port.rawName, msgh_local_port: 0,
        msgh_voucher_port: 0, msgh_id: messageID)
      Wire.write(UInt64(frame.count), to: raw, at: headerSize, width: 4)
      raw.baseAddress!.advanced(by: headerSize + 4).copyMemory(from: frame.baseAddress!, byteCount: frame.count)
      let result = mach_msg(header, mach_msg_option_t(MACH_SEND_MSG | MACH_SEND_TIMEOUT), UInt32(size), 0, 0, 0, 0)
      guard result == MACH_MSG_SUCCESS else { throw HostError("device send", code: result) }
    }
  }
  private func drain() {
    let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
    let headerSize = MemoryLayout<mach_msg_header_t>.size
    while true {
      let result = mach_msg(header, mach_msg_option_t(MACH_RCV_MSG | MACH_RCV_TIMEOUT), 0,
        UInt32(Self.bufferSize), right.port.rawName, 0, 0)
      guard result == MACH_MSG_SUCCESS else { return }
      let size = Int(header.pointee.msgh_size)
      if header.pointee.msgh_id == Self.messageID, header.pointee.msgh_bits & MACH_MSGH_BITS_COMPLEX == 0,
        size >= headerSize + 4, size <= Self.bufferSize {
        let bytes = UnsafeRawBufferPointer(start: buffer, count: size)
        let length = Int(Wire.read(bytes,headerSize,4))
        if length >= 32, length <= 32 + Wire.maximumPayload, size == (headerSize + 4 + length + 3) & ~3 {
          let frame = UnsafeRawBufferPointer(rebasing: bytes[(headerSize+4)..<(headerSize+4+length)])
          if FrameView(frame) != nil { handler(frame) }
        }
      }
      mach_msg_destroy(header)
    }
  }
}
