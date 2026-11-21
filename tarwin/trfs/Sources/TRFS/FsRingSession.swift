import TarwinFsWire
import TarwinIPC

public enum FsPublish: Equatable {
  case rejected
  case ring(RingStep)
}
public enum FsPoll: Equatable {
  case wait, disconnected, invalidReply, retiring
  case completed
}
/// Proof of retirement issued by the mount only after synchronous revocation.
/// A nil status denotes server loss. Volume and epoch are kernel identities.
public struct FsReceipt {
  public let volume: UInt64, epoch: UInt64, request: UInt64, status: FsStatus?, count: UInt32
  fileprivate init(_ v: UInt64, _ e: UInt64, _ id: UInt64, _ s: FsStatus?, _ n: UInt32) {
    volume = v
    epoch = e
    request = id
    status = s
    count = n
  }
}
/// Exclusive owner of one fresh A.4 pair and all request-exclusive grants
/// for this volume's server. Serialize access under the volume lock.
public struct FsRingSession: ~Copyable {
  private var channel: FsChannel, requests: RingEndpoint, replies: RingEndpoint
  private var terminal: FsReply?, failed = false
  public var live: Int { channel.live }
  public var volume: UInt64 { channel.volume }
  public var epoch: UInt64 { channel.epoch }
  public var lastPublished: UInt64 { channel.last }
  public init?(
    volume: UInt64, epoch: UInt64, limit: Int, requests: consuming RingEndpoint,
    replies: consuming RingEndpoint
  ) {
    guard volume != 0, epoch != 0, (1...65536).contains(limit) else { return nil }
    channel = FsChannel(volume: volume, epoch: epoch, limit: limit)
    channel.pending.reserveCapacity(limit)
    self.requests = requests
    self.replies = replies
  }
  public mutating func submit(
    _ op: FsOp, node: VolumeNode, other: VolumeNode, offset: UInt64, input: UInt64,
    inputBytes: UInt32, output: UInt64, outputBytes: UInt32,
    resolveShare: (UInt64) -> FsShare?
  ) -> FsPublish {
    guard !failed else { return .rejected }
    var outcome: FsPublish = .rejected
    _ = channel.begin(
      op, node, other, offset, input, inputBytes, output, outputBytes, resolveShare
    ) { r in
      let step = requests.push(r.record())
      outcome = .ring(step)
      switch step {
      case .transferred: return true
      case .wait: return false
      default:
        failed = true
        return false
      }
    }
    return outcome
  }
  /// A consumed completion stays private and immutable across failed
  /// synchronous revocation. The caller may expose output only in deliver.
  public mutating func poll(
    signalSpace: () -> Void, revoke: (FsRecord) -> Bool, deliver: (FsRecord, FsReply) -> Void
  )
    -> FsPoll
  {
    guard !failed else { return .disconnected }
    if terminal == nil {
      var r = RingRecord()
      switch replies.pop(into: &r) {
      case .wait: return .wait
      case .transferred(let wake): if wake { signalSpace() }
      default:
        failed = true
        return .invalidReply
      }
      guard let done = FsReply(record: r), done.epoch == channel.epoch,
        let p = channel.pending.prefix(channel.live).first(where: { $0.record.id == done.id }),
        done.produced <= p.record.outputBytes
      else {
        failed = true
        return .invalidReply
      }
      terminal = done
    }
    let done = terminal!
    var retired: FsRecord?
    guard
      channel.finish(
        done.epoch, done.id, done.produced,
        { r in
          guard revoke(r) else { return false }
          retired = r
          return true
        })
    else { return .retiring }
    terminal = nil
    deliver(retired!, done)
    return .completed
  }
  /// Call even after a protocol fault. Retry until all old accesses have
  /// been revoked; never reuse the endpoint mapping for a replacement server.
  public mutating func disconnect(revoke: (FsRecord) -> Bool, fail: (UInt64) -> Void) -> Bool {
    failed = true
    terminal = nil
    return channel.disconnect(revoke, fail)
  }
  public mutating func pollRetired(
    signalSpace: () -> Void, revoke: (FsRecord) -> Bool, deliver: (FsReceipt) -> Void
  ) -> FsPoll {
    let v = volume
    let e = epoch
    return poll(signalSpace: signalSpace, revoke: revoke) { r, reply in
      deliver(FsReceipt(v, e, r.id, reply.status, reply.produced))
    }
  }
  public mutating func disconnectRetired(revoke: (FsRecord) -> Bool, fail: (FsReceipt) -> Void)
    -> Bool
  {
    let v = volume
    let e = epoch
    return disconnect(revoke: revoke) { fail(FsReceipt(v, e, $0, nil, 0)) }
  }
}
