/// One serialized manager-owned selection pass for one node. The registry
/// gives each pass a fresh never-reused generation, including on replug.
/// A personality may be launched only after its probe ticket is issued.
public struct ProbeTicket: Equatable {
  public let generation: UInt64, candidate: String
  fileprivate init(_ generation: UInt64, _ candidate: String) {
    self.generation = generation
    self.candidate = candidate
  }
}

public struct DriverProbes: ~Copyable {
  public enum Phase: Equatable {
    case selecting, probing, starting, retiring, bound, discovered, removed
  }
  private let generation: UInt64, ranked: [String]
  private var next = 0, ticket: ProbeTicket?, gone = false
  public private(set) var phase: Phase = .selecting

  public init?(generation: UInt64, ranked: [String]) {
    guard generation != 0, Set(ranked).count == ranked.count, ranked.allSatisfy({ !$0.isEmpty })
    else { return nil }
    self.generation = generation
    self.ranked = ranked
  }

  public mutating func nextProbe(noticeUnmatched: () -> Void) -> ProbeTicket? {
    guard phase == .selecting else { return nil }
    guard next < ranked.count else {
      phase = .discovered
      noticeUnmatched()
      return nil
    }
    let t = ProbeTicket(generation, ranked[next])
    next += 1
    ticket = t
    phase = .probing
    return t
  }

  @discardableResult public mutating func probed(_ t: ProbeTicket, accepted: Bool) -> Bool {
    guard ticket == t, phase == .probing else { return false }
    phase = accepted ? .starting : .retiring
    return true
  }
  @discardableResult public mutating func started(_ t: ProbeTicket, success: Bool) -> Bool {
    guard ticket == t, phase == .starting else { return false }
    phase = success ? .bound : .retiring
    return true
  }

  /// Only after the supervisor's restart budget for this personality runs out.
  @discardableResult public mutating func exhausted(_ t: ProbeTicket) -> Bool {
    guard ticket == t, phase == .bound else { return false }
    phase = .retiring
    return true
  }
  public mutating func remove() {
    gone = true
    phase = ticket == nil ? .removed : .retiring
  }

  /// Stop the exact job and synchronously revoke its resources before another
  /// candidate can probe. Failed drain leaves the node held for retry.
  public mutating func retire(_ t: ProbeTicket, stopAndDrain: (ProbeTicket) -> Bool) -> Bool {
    guard phase == .retiring, ticket == t, stopAndDrain(t) else { return false }
    ticket = nil
    phase = gone ? .removed : .selecting
    return true
  }
}
