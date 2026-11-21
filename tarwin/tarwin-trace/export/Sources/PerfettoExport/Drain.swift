import TarwinTrace

public enum TraceSource { case kernelCPU, userThread }
public enum DrainResult: Equatable { case empty, progress, backpressure, invalid }

/// One service-owned cursor per mapped ring. The caller creates the regular
/// track before draining; counterTrack resolves a declared, distinct counter
/// track within this source (never treats a user subject as a track UUID).
public struct TraceDrain {
  public let source: TraceSource
  public let capacity, track: UInt64
  public private(set) var consumed: UInt64 = 0
  private var lastTime: UInt64 = 0

  public init?(source: TraceSource, capacity: UInt64, track: UInt64) {
    guard track != 0, (64...65536).contains(capacity), capacity.nonzeroBitCount == 1 else {
      return nil
    }
    self.source = source
    self.capacity = capacity
    self.track = track
  }

  // head was acquired; copy returns a by-value snapshot, or nil on invalid
  // shared bytes. sink accepts a complete packet or none before releaseTail.
  public mutating func step(
    head: UInt64, copy: (UInt64) -> TraceRecord?,
    counterTrack: (UInt64) -> UInt64?, sink: ([UInt8]) -> Bool,
    releaseTail: (UInt64) -> Void
  ) -> DrainResult {
    guard head >= consumed, head - consumed <= capacity else { return .invalid }
    guard head != consumed else { return .empty }
    guard let record = copy(consumed & (capacity - 1)), record.monotonicNanos >= lastTime else {
      return .invalid
    }
    let user: Bool
    let name: String
    var kind: TrackType = .instant
    var id = track
    switch record.kind {
    case .userBegin: (user, name, kind) = (true, "begin", .begin)
    case .userEnd: (user, name, kind) = (true, "end", .end)
    case .userInstant: (user, name) = (true, "instant")
    case .userCounter:
      guard source == .userThread, let counter = counterTrack(record.subject), counter != 0,
        counter != track
      else { return .invalid }
      (user, name, kind, id) = (true, "counter", .counter, counter)
    case .contextSwitch: (user, name) = (false, "context switch")
    case .wake: (user, name) = (false, "wake")
    case .interrupt: (user, name) = (false, "interrupt")
    case .syscall: (user, name) = (false, "syscall")
    case .fault: (user, name) = (false, "page fault")
    case .block: (user, name) = (false, "block I/O")
    case .network: (user, name) = (false, "network I/O")
    case .fence: (user, name) = (false, "fence")
    case .power: (user, name) = (false, "power")
    }
    guard user == (source == .userThread) else { return .invalid }
    let packet = perfettoEvent(
      id, record.monotonicNanos, kind, user ? "user" : "kernel", name,
      record.value, subject: record.subject, value: record.value)
    guard sink(packet) else { return .backpressure }
    lastTime = record.monotonicNanos
    consumed += 1
    releaseTail(consumed)
    return .progress
  }
}
