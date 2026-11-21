/// Single-port console (no MULTIPORT) and entropy use unframed byte queues.
/// Input goes only to an exclusive staging grant, never directly to a client.
/// The entropy consumer must mix untrusted input without crediting entropy.
public enum ByteChannel {
  case consoleReceive, consoleTransmit, entropy
  public var device: UInt16 { self == .entropy ? 4 : 3 }
  public var index: Int { self == .consoleTransmit ? 1 : 0 }
  public var deviceWrites: Bool { self != .consoleTransmit }
}

public enum ByteDelivery: Equatable {
  case consoleInput(UInt32)
  case consoleSent(UInt32)
  case uncreditedRandom(UInt32)
  case dropped
}
/// Serialized owner of one device queue; its scratch span is dedicated to
/// this channel. Keep the pin until release succeeds, even after reset.
public struct ByteStreamQueue: ~Copyable {
  public let channel: ByteChannel
  private var ring = SplitQueue()
  private var next: UInt64 = 0, cookie: UInt64 = 0, capacity: UInt32 = 0
  private var result: ByteDelivery?, stopped = false
  public var consumed: UInt16 { ring.consumed }
  public init?(channel: ByteChannel, count: Int) {
    self.channel = channel
    guard ring.initialize(count) else { return nil }
  }
  /// Caller resolves a live direction-limited grant and prepares/synchronizes
  /// staging before publication. A false result never publishes a descriptor.
  public mutating func submit(
    iova: UInt64, length: UInt32,
    descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void,
    available: (Int, UInt16) -> Void, publish: (UInt16) -> Void
  ) -> Bool {
    guard !stopped, cookie == 0, next != .max, length > 0, length <= 65536 else { return false }
    let id = next + 1
    guard
      ring.submit(
        id, [Segment(iova: iova, length: length, deviceWrites: channel.deviceWrites)], descriptor,
        available, publish)
    else { return false }
    next = id
    cookie = id
    capacity = length
    return true
  }
  public mutating func poll(acquire: () -> UInt16, head: (Int) -> UInt32, written: (Int) -> UInt32)
  {
    guard !stopped, cookie != 0, result == nil else { return }
    switch ring.consume(acquire, head, written) {
    case .empty: return
    case .broken: stop()
    case .completed(let used):
      guard used.cookie == cookie else {
        stop()
        return
      }
      switch channel {
      case .consoleReceive: result = .consoleInput(used.written)
      case .consoleTransmit: result = .consoleSent(capacity)
      case .entropy:
        if used.written == 0 { stop() } else { result = .uncreditedRandom(used.written) }
      }
    }
  }
  public mutating func stop() {
    stopped = true
    if cookie != 0 { result = .dropped }
  }
  /// After stop or malformed ring, drain includes queue reset and IOTLB/ATC
  /// invalidation. Short input exposes only the used prefix. Caller scrubs
  /// the whole span before re-grant and never replays a console write.
  public mutating func release(drain: () -> Bool) -> ByteDelivery? {
    guard let done = result, drain() else { return nil }
    cookie = 0
    capacity = 0
    result = nil
    return done
  }
}
