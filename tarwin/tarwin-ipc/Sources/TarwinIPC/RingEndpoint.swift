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
  var isPortCompletionProducer: Bool { completion && producer && geometry.stride == 64 }
  public var isPortCompletionReader: Bool { completion && !producer && geometry.stride == 64 }
  fileprivate var geometryCount: UInt32 { geometry.count }
  var completionMapping: UInt { UInt(bitPattern: words.baseAddress) }
  var publishedThrough: UInt32 { local }

  /// Even after the last producer cursor was published, consumption may
  /// advance up to it, but cannot move backwards or acknowledge future data.
  mutating func consumedThrough(armNotification: Bool) -> UInt32? {
    guard isPortCompletionProducer, !failed else { return nil }
    // Publish idle before sampling the peer. Either this read sees its
    // advance, or its post-publication idle check observes the request.
    if armNotification && lastPeer < local {
      words[idle].store(1, ordering: .sequentiallyConsistent)
    }
    let seen = words[peerCursor].load(ordering: .sequentiallyConsistent)
    guard ringConsumerValid(lastPeer, seen, local) else {
      failed = true
      words[idle].store(0, ordering: .releasing)
      return nil
    }
    lastPeer = seen
    if seen == local { words[idle].store(0, ordering: .releasing) }
    return seen
  }

  fileprivate mutating func peerReady() -> RingStep? {
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

  fileprivate mutating func publish() -> RingStep {
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
    copyAtCursor(into: &record)
    return publish()
  }

  fileprivate func copyAtCursor(into record: inout RingRecord) {
    let first = Int(geometry.offset(local, completion)) / 4
    record = RingRecord()
    for i in 0..<Int(geometry.stride / 4) {
      record.words[i] = words[first + i].load(ordering: .relaxed)
    }
  }
}

public enum SubmissionStop { case idle, capacity, budget, invalidPeer, exhausted }

public struct SubmissionBatch {
  public let count: UInt32
  public let notifyPeer: Bool
  public let stop: SubmissionStop
}

/// One kernel reader per fresh, pinned port mapping. On backend pressure,
/// hold the private copy without acknowledging the caller's submission.
public struct PortSubmissions: ~Copyable {
  private var endpoint: RingEndpoint
  private var held: RingRecord?
  public init?(fresh words: UnsafeBufferPointer<Atomic<UInt32>>) {
    guard let ep = RingEndpoint(fresh: words, completion: false, producer: false),
      ep.isPortRequestReader
    else { return nil }
    endpoint = ep
  }

  /// Both halves must have captured identical geometry before the mapping
  /// was published. A peer changing the header between attaches cannot make
  /// the submission area overlap the completion area.
  public func isPaired(with completion: borrowing RingEndpoint) -> Bool {
    completion.isPortCompletionProducer && completion.completionMapping == endpoint.completionMapping
      && completion.geometryCount == endpoint.geometryCount
  }

  /// Under the submission lock, stage bounded work for a trusted backend.
  /// Return true only after reserving its completion and assuming ownership
  /// of every operand, or committing a terminal error. A false return must
  /// have no side effects. Never re-enter the ring in this callback.
  /// On capacity, retry on backend progress; on budget, schedule another turn.
  public mutating func drain(
    budget: UInt32, capture: (borrowing RingRecord) -> Bool
  ) -> SubmissionBatch {
    var count: UInt32 = 0
    var wake = false
    while count < min(budget, 64) {
      if let step = endpoint.peerReady() {
        let stop: SubmissionStop
        switch step {
        case .wait: stop = .idle
        case .exhausted: stop = .exhausted
        default: stop = .invalidPeer
        }
        return SubmissionBatch(count: count, notifyPeer: wake, stop: stop)
      }
      if held == nil {
        var copy = RingRecord()
        endpoint.copyAtCursor(into: &copy)
        held = copy
      }
      guard capture(held!) else {
        return SubmissionBatch(count: count, notifyPeer: wake, stop: .capacity)
      }
      held = nil
      if case .transferred(let notify) = endpoint.publish() { wake = wake || notify }
      count += 1
    }
    return SubmissionBatch(count: count, notifyPeer: wake, stop: .budget)
  }
}

extension RingEndpoint {
  fileprivate var isPortRequestReader: Bool { !completion && !producer && geometry.stride == 64 }
}
