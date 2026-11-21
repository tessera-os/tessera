import TarwinIPC
import TarwinNetWire
import VirtioGuest

public struct PendingNetFrame {
  public let request: NetFrame, packet: NetPacket
  public func complete(cookie: UInt64, written: UInt32, flags: UInt8, gso: UInt8) -> NetFrameDone? {
    guard cookie == request.id else { return nil }
    let count: UInt32
    switch frameResult(request.direction == .receive, request.bytes, written, flags, gso) {
    case .sent: count = request.bytes
    case .received(let n): count = n
    case .invalid: return nil
    }
    return NetFrameDone(
      direction: request.direction, queue: request.queue, id: request.id, epoch: request.epoch,
      bytes: count)
  }
}
/// header belongs to the driver, not to the sending process. Accept only
/// the current interface grant and the expected direction of this queue.
public func prepareNetFrame(
  _ r: borrowing RingRecord, epoch: UInt64, queue: UInt32, direction: NetDirection,
  maximum: UInt32, header: UInt64, grant: (UInt64, UInt32, Bool) -> Bool
) -> PendingNetFrame? {
  guard let f = NetFrame(record: r), f.epoch == epoch, f.queue == queue, f.direction == direction,
    f.bytes <= maximum, maximum <= 65553, direction != .receive || f.bytes == maximum,
    header <= UInt64.max - 11
  else { return nil }
  if f.iova >= header ? f.iova - header < 12 : header - f.iova < UInt64(f.bytes) { return nil }
  guard grant(f.iova, f.bytes, direction == .receive) else { return nil }
  return PendingNetFrame(
    request: f, packet: NetPacket(header: header, frame: f.iova, bytes: f.bytes))
}
