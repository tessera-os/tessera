// Modern single-buffer virtio-net. No merge, checksum/segmentation offload,
// HASH_REPORT, or GUEST_HDRLEN; the virtio 1.x base header is twelve bytes.
public struct NetPacket: Equatable {
  public let header: UInt64
  public let frame: UInt64
  public let bytes: UInt32

  public init(header: UInt64, frame: UInt64, bytes: UInt32) {
    self.header = header
    self.frame = frame
    self.bytes = bytes
  }
}

public func submitFrame(
  _ queue: inout SplitQueue, _ cookie: UInt64, _ packet: NetPacket, _ receive: Bool,
  _ maximumFrame: UInt32, _ clearHeader: (UInt64, UInt32) -> Void,
  _ descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void,
  _ putAvailable: (Int, UInt16) -> Void, _ releaseAvailable: (UInt16) -> Void
) -> Bool {
  if packet.bytes < 14 || packet.bytes > maximumFrame || (receive && packet.bytes < maximumFrame)
    || maximumFrame > 65553 || !validArea(packet.header, 12, 1)
    || !validArea(packet.frame, UInt64(packet.bytes), 1)
    || !distinctAreas(packet.header, 12, packet.frame, UInt64(packet.bytes))
  {
    return false
  }
  let parts = [
    Segment(iova: packet.header, length: 12, deviceWrites: receive),
    Segment(iova: packet.frame, length: packet.bytes, deviceWrites: receive),
  ]
  clearHeader(packet.header, 12)
  return queue.submit(cookie, parts, descriptor, putAvailable, releaseAvailable)
}

public enum FrameResult: Equatable {
  case invalid
  case sent
  case received(UInt32)
}
public func frameResult(
  _ receive: Bool, _ capacity: UInt32, _ written: UInt32, _ flags: UInt8, _ gso: UInt8
) -> FrameResult {
  if !receive { return written == 0 ? FrameResult.sent : FrameResult.invalid }
  if written < 26 || written - 12 > capacity || flags != 0 || gso != 0 { return .invalid }
  return .received(written - 12)
}
