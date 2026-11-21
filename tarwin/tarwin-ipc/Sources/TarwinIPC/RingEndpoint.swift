import Synchronization

public struct RingRecord {
  public var words = InlineArray<32, UInt32>(repeating: 0)
  public init() {}
}

public enum RingStep: Equatable {
  case transferred(notifyPeer: Bool)
  case wait, exhausted, invalidPeer, wrongSide
}

/// Exactly one endpoint owns each local cursor (serialize concurrent
/// callers outside this type). The caller pins a little-endian shared
/// mapping of initialized atomic words until both endpoints detach.
public struct RingEndpoint: ~Copyable {
  private let words: UnsafeBufferPointer<Atomic<UInt32>>
  private let geometry: RingGeometry
  private let completion: Bool
  private let producer: Bool
  private let control: Int
  private var local: UInt32 = 0
  private var lastPeer: UInt32 = 0
  private var failed = false

  /// Attach while the new ring is quiescent. Never reinterpret a reset
  /// or previously exhausted mapping as a new channel with the same peer.
  public init?(fresh words: UnsafeBufferPointer<Atomic<UInt32>>, completion: Bool, producer: Bool) {
    guard words.count >= 1024, MemoryLayout<Atomic<UInt32>>.stride == 4,
      let base = words.baseAddress, UInt(bitPattern: base) & 63 == 0
    else { return nil }
    let magic = words[0].load(ordering: .acquiring)
    let info = words[1].load(ordering: .acquiring)
    let geometry = RingGeometry(
      count: words[2].load(ordering: .acquiring), stride: words[3].load(ordering: .acquiring))
    guard ringHeaderAllowed(magic, UInt16(truncatingIfNeeded: info), UInt16(info >> 16)),
      UInt64(words.count) <= UInt64.max / 4, geometry.fits(UInt64(words.count) * 4)
    else { return nil }
    let head = Int(completion ? RingFormat.completionProducer : RingFormat.requestProducer) / 4
    for line in 0..<4 where words[head + 16 * line].load(ordering: .acquiring) != 0 { return nil }
    self.words = words
    self.geometry = geometry
    self.completion = completion
    self.producer = producer
    control = head
  }

  private var cursor: Int { producer ? control : control + 16 }
  private var peerCursor: Int { producer ? control + 16 : control }
  private var idle: Int { cursor + 32 }
  private var peerIdle: Int { peerCursor + 32 }

  private mutating func peerReady() -> RingStep? {
    if failed { return .invalidPeer }
    if local == .max { return .exhausted }
    // Pairs with the peer's publish-then-check-idle sequence. The SC
    // ordering rules out both sides observing their old values.
    for attempt in 0..<2 {
      let seen = words[peerCursor].load(ordering: .sequentiallyConsistent)
      let valid =
        producer
        ? ringConsumerValid(lastPeer, seen, local)
        : ringProducerValid(lastPeer, seen, local, geometry.count)
      guard valid else {
        failed = true
        words[idle].store(0, ordering: .releasing)
        return .invalidPeer
      }
      lastPeer = seen
      if producer ? local - seen < geometry.count : seen > local {
        words[idle].store(0, ordering: .releasing)
        return nil
      }
      if attempt == 0 { words[idle].store(1, ordering: .sequentiallyConsistent) }
    }
    // Wait on a latched Event: a signal before the caller sleeps persists.
    return .wait
  }

  private mutating func publish() -> RingStep {
    local += 1
    words[cursor].store(local, ordering: .sequentiallyConsistent)
    return .transferred(notifyPeer: words[peerIdle].load(ordering: .sequentiallyConsistent) != 0)
  }

  public mutating func push(_ record: borrowing RingRecord) -> RingStep {
    guard producer else { return .wrongSide }
    if let error = peerReady() { return error }
    let first = Int(geometry.offset(local, completion)) / 4
    for i in 0..<Int(geometry.stride / 4) {
      words[first + i].store(record.words[i], ordering: .relaxed)
    }
    return publish()
  }

  /// Returns a private copy. Validate every operand before acting on it;
  /// a hostile peer may modify any shared word at any time.
  public mutating func pop(into record: inout RingRecord) -> RingStep {
    guard !producer else { return .wrongSide }
    if let error = peerReady() { return error }
    let first = Int(geometry.offset(local, completion)) / 4
    record = RingRecord()
    for i in 0..<Int(geometry.stride / 4) {
      record.words[i] = words[first + i].load(ordering: .relaxed)
    }
    return publish()
  }
}
