import TarwinFsWire
import TarwinIPC

/// Resolves only the named request's exact, volume-local share. Stores are
/// all-or-nothing. No mapped view survives the return of either method.
public protocol FatShares: ~Copyable {
  mutating func load(request: UInt64, share: UInt64, length: UInt32) -> [UInt8]?
  mutating func store(request: UInt64, share: UInt64, capacity: UInt32, bytes: [UInt8]) -> Bool
}

public enum FatStep: Equatable { case waitRequest, waitReply, replied, stopped }

public struct FatServer<M: FatMedia>: ~Copyable {
  private let volume: FatVolume<M>, epoch: UInt64
  private var requests: RingEndpoint, replies: RingEndpoint, pending: FsReply?, last: UInt64 = 0,
    stopped = false
  public init?(
    volume: FatVolume<M>, epoch: UInt64, requests: consuming RingEndpoint,
    replies: consuming RingEndpoint
  ) {
    guard epoch != 0 else { return nil }
    self.volume = volume
    self.epoch = epoch
    self.requests = requests
    self.replies = replies
  }
  /// One reply may be retained under backpressure. Flush it before consuming
  /// another request; in particular, never repeat a share write on retry.
  public mutating func step<S: FatShares & ~Copyable>(
    shares: inout S, signalSpace: () -> Void, signalReply: () -> Void
  ) -> FatStep {
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
      let (status, n) = serve(r, shares: &shares)
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
  private func serve<S: FatShares & ~Copyable>(_ r: FsRecord, shares: inout S) -> (FsStatus, UInt32)
  {
    do {
      let bytes: [UInt8]
      let node = try volume.node(r.node)
      switch r.op {
      case .lookup:
        guard r.offset == 0, (1...12).contains(r.inputBytes), r.outputBytes >= 8 else {
          return (.invalid, 0)
        }
        guard let name = shares.load(request: r.id, share: r.input, length: r.inputBytes),
          name.count == Int(r.inputBytes)
        else { return (.denied, 0) }
        let id = try volume.lookup(parent: node.id, name: name)
        bytes = (0..<8).map { UInt8(truncatingIfNeeded: id >> ($0 * 8)) }
      case .read:
        guard r.input == 0, r.outputBytes <= 1 << 20 else { return (.invalid, 0) }
        bytes = try volume.bytes(node: node.id, offset: r.offset, count: Int(r.outputBytes))
      case .readDirectory, .getAttributes:
        guard r.input == 0, r.outputBytes > 0 else { return (.invalid, 0) }
        let entry: FatNode
        if r.op == .readDirectory {
          guard let n = try volume.entry(parent: node.id, index: r.offset) else { return (.ok, 0) }
          entry = n
        } else {
          guard r.offset == 0 else { return (.invalid, 0) }
          entry = node
        }
        bytes = FsEntry(
          id: entry.id, size: UInt64(entry.size), directory: entry.directory,
          name: Array(entry.name.utf8))!.bytes()
      case .flush, .sync:
        guard r.input == 0, r.output == 0, r.offset == 0 else { return (.invalid, 0) }
        return (.ok, 0)
      case .write, .setAttributes, .create, .remove, .rename, .link, .symbolicLink, .setXattr,
        .removeXattr:
        return (.readOnly, 0)
      default: return (.unsupported, 0)
      }
      guard bytes.count <= r.outputBytes else { return (.noSpace, 0) }
      if !bytes.isEmpty
        && !shares.store(request: r.id, share: r.output, capacity: r.outputBytes, bytes: bytes)
      {
        return (.denied, 0)
      }
      return (.ok, UInt32(bytes.count))
    } catch FatError.notFound { return (.notFound, 0) } catch FatError.notDirectory {
      return (.notDirectory, 0)
    } catch FatError.io { return (.io, 0) } catch { return (.invalid, 0) }
  }
}
