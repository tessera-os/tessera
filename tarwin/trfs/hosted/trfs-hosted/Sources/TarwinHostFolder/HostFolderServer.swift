import TarwinFsWire
import TarwinIPC
import TarwinReadOnlyFS

/// The A.5 ring loop for a granted Mac folder. Same contract as
/// ReadOnlyServer: one reply is retained under backpressure, request ids
/// must increase, and a malformed record stops the server.
public struct HostFolderServer: ~Copyable {
  public let volume: HostFolderVolume
  private let epoch: UInt64
  private var requests: RingEndpoint, replies: RingEndpoint, pending: FsReply?, last: UInt64 = 0,
    stopped = false
  public init?(
    volume: HostFolderVolume, epoch: UInt64, requests: consuming RingEndpoint,
    replies: consuming RingEndpoint
  ) {
    guard epoch != 0 else { return nil }
    self.volume = volume
    self.epoch = epoch
    self.requests = requests
    self.replies = replies
  }
  public mutating func step<S: ReadOnlyShares & ~Copyable>(
    shares: inout S, signalSpace: () -> Void, signalReply: () -> Void
  ) -> ReadOnlyStep {
    guard !stopped else { return .stopped }
    if pending == nil {
      var wire = RingRecord()
      switch requests.pop(into: &wire) {
      case .wait: return .waitRequest
      case .transferred(let wake): if wake { signalSpace() }
      default:
        stopped = true
        return .stopped
      }
      guard let r = FsRecord(record: wire), r.id > last else {
        stopped = true
        return .stopped
      }
      last = r.id
      let (status, n) = volume.handle(r, shares: &shares)
      pending = FsReply(epoch: epoch, id: r.id, status: status, produced: n)!
    }
    switch replies.push(pending!.record()) {
    case .wait: return .waitReply
    case .transferred(let wake):
      pending = nil
      if wake { signalReply() }
      return .replied
    default:
      stopped = true
      return .stopped
    }
  }
}
