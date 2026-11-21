import Synchronization
import TarwinIPC

public enum IoRingResult: Equatable { case ready, transferred, wait, invalid, exhausted }

/// Pinned, coherent shared Memory, page aligned and mapped for the lifetime
/// of every lane. The exclusive creator initializes the fields ONCE before
/// granting the peer access; an arbitrary existing ring must never be reset.
public struct IoRingMapping {
  private let base: UnsafeMutableRawPointer
  private let geometry: RingGeometry

  private static func suitable(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
    guard let base = bytes.baseAddress else { return false }
    return bytes.count >= Int(RingFormat.records) && UInt(bitPattern: base) % 64 == 0
  }

  public static func initialize(
    _ bytes: UnsafeMutableRawBufferPointer, count: UInt32, stride: UInt32
  ) -> Bool {
    let geometry = RingGeometry(count: count, stride: stride)
    guard suitable(bytes), geometry.fits(UInt64(bytes.count)), let base = bytes.baseAddress else {
      return false
    }
    // No peer can observe this initialization. Bind distinct, naturally
    // aligned atomic words in the header and atomic octets in both record slabs.
    func header(_ at: Int, _ v: UInt32) {
      base.advanced(by: at).bindMemory(to: Atomic<UInt32>.self, capacity: 1)
        .initialize(to: Atomic(v.littleEndian))
    }
    header(0, RingFormat.magic)
    header(4, UInt32(RingFormat.version))
    header(8, count)
    header(12, stride)
    for i in 1...8 {
      base.advanced(by: i * 64).bindMemory(to: Atomic<UInt32>.self, capacity: 1).initialize(
        to: Atomic(0))
    }
    let length = 2 * Int(count) * Int(stride)
    let records = base.advanced(by: Int(RingFormat.records)).bindMemory(
      to: Atomic<UInt8>.self, capacity: length)
    for i in 0..<length { records.advanced(by: i).initialize(to: Atomic(0)) }
    return true
  }

  public init?(attaching bytes: UnsafeMutableRawBufferPointer) {
    guard Self.suitable(bytes), let base = bytes.baseAddress else { return nil }
    func word(_ offset: Int) -> UInt32 {
      UInt32(
        littleEndian: base.advanced(by: offset).assumingMemoryBound(to: Atomic<UInt32>.self)
          .pointee.load(ordering: .acquiring))
    }
    let magic = word(0)
    let format = word(4)
    let count = word(8)
    let stride = word(12)
    guard ringHeaderAllowed(magic, UInt16(truncatingIfNeeded: format), UInt16(format >> 16)) else {
      return nil
    }
    let geometry = RingGeometry(count: count, stride: stride)
    guard geometry.fits(UInt64(bytes.count)) else { return nil }
    self.base = base
    self.geometry = geometry
  }

  /// Open exactly once for each single producer/consumer on a fresh ring
  /// epoch, before publishing either endpoint to its owner.
  public func lane(completion: Bool, producer: Bool) -> IoRingLane {
    IoRingLane(base: base, geometry: geometry, completion: completion, producer: producer)
  }
}

public struct IoRingLane: ~Copyable {
  private let base: UnsafeMutableRawPointer, geometry: RingGeometry
  private let completion: Bool, producer: Bool
  private let own: UInt64, peer: UInt64, ownIdle: UInt64, peerIdle: UInt64
  private var position: UInt32 = 0, lastPeer: UInt32 = 0, poisoned = false
  fileprivate init(
    base: UnsafeMutableRawPointer, geometry: RingGeometry, completion: Bool, producer: Bool
  ) {
    self.base = base
    self.geometry = geometry
    self.completion = completion
    self.producer = producer
    let p = completion ? RingFormat.completionProducer : RingFormat.requestProducer
    let c = completion ? RingFormat.completionConsumer : RingFormat.requestConsumer
    let pi = completion ? RingFormat.completionProducerIdle : RingFormat.requestProducerIdle
    let ci = completion ? RingFormat.completionConsumerIdle : RingFormat.requestConsumerIdle
    own = producer ? p : c
    peer = producer ? c : p
    ownIdle = producer ? pi : ci
    peerIdle = producer ? ci : pi
  }

  // Offsets are from captured, validated geometry or fixed A.4 header
  // constants, never a pointer/stride from a peer-controlled record.
  private func atom(_ offset: UInt64) -> UnsafeMutablePointer<Atomic<UInt32>> {
    base.advanced(by: Int(offset)).assumingMemoryBound(to: Atomic<UInt32>.self)
  }
  private mutating func availability() -> IoRingResult {
    if poisoned { return .invalid }
    let seen = UInt32(littleEndian: atom(peer).pointee.load(ordering: .acquiring))
    if producer
      ? !ringConsumerValid(lastPeer, seen, position)
      : !ringProducerValid(lastPeer, seen, position, geometry.count)
    {
      poisoned = true
      return .invalid
    }
    lastPeer = seen
    if position == .max { return .exhausted }
    if producer ? position - seen == geometry.count : position == seen { return .wait }
    return .ready
  }

  /// The private record buffer must not alias shared memory. For a consumer
  /// it is a single snapshot: validate the copied protocol fields before use.
  public mutating func transfer(
    _ record: UnsafeMutableBufferPointer<UInt8>,
    signal: () -> Void
  ) -> IoRingResult {
    guard record.count == geometry.stride else { return .invalid }
    atom(ownIdle).pointee.store(0, ordering: .releasing)
    let status = availability()
    guard status == .ready else { return status }
    let row = base.advanced(by: Int(geometry.offset(position, completion))).assumingMemoryBound(
      to: Atomic<UInt8>.self)
    for i in record.indices {
      if producer {
        row[i].store(record[i], ordering: .relaxed)
      } else {
        record[i] = row[i].load(ordering: .relaxed)
      }
    }
    position += 1
    atom(own).pointee.store(position.littleEndian, ordering: .releasing)
    // Pair with arm's store-load fence so the idle flag and updated cursor
    // cannot both be missed. The event must retain a pre-wait signal.
    atomicMemoryFence(ordering: .sequentiallyConsistent)
    if atom(peerIdle).pointee.load(ordering: .acquiring) != 0 { signal() }
    return .transferred
  }

  /// Register the port/Event waiter before arm, sleep only on .wait.
  /// Always retry transfer after wake (including spurious wakeups).
  public mutating func arm() -> IoRingResult {
    atom(ownIdle).pointee.store(UInt32(1).littleEndian, ordering: .releasing)
    atomicMemoryFence(ordering: .sequentiallyConsistent)
    let status = availability()
    if status != .wait { atom(ownIdle).pointee.store(0, ordering: .releasing) }
    return status
  }
}
