public enum ClockUpdate {
  case stepUTC(UInt64), slewUTC(Int64)
  case leap(LeapSecond, startingAtBoot: UInt64)
  case suspend, resume(sleptNS: UInt64)
}

/// The sole owner of a pinned time page and its kernel clock state.
/// Serialize counter sampling, updates and timer replanning under the clock
/// lock. The service or power controller must authorize its operation first.
@available(macOS 15, *)
public struct PublishedClocks: ~Copyable {
  private let writer: TimePageWriter
  public private(set) var snapshot: SystemClocks?

  @unsafe public init?(freshPage: UnsafeMutableRawBufferPointer, clock: SystemClocks) {
    guard let writer = TimePageWriter(freshPage: freshPage), writer.publish(clock) else { return nil }
    self.writer = consume writer
    snapshot = clock
  }

  /// Bad inputs leave both views unchanged. Sequence exhaustion instead
  /// closes both until the page can be replaced after all readers retire.
  public mutating func update(_ change: ClockUpdate, counter: UInt64) -> Bool {
    guard var next = snapshot else { return false }
    let ok = switch change {
    case .stepUTC(let utc): next.stepUTC(to: utc, counter: counter)
    case .slewUTC(let ns): next.slewUTC(by: ns, counter: counter)
    case .leap(let leap, let start): next.scheduleLeap(leap, startingAtBoot: start, counter: counter)
    case .suspend: next.suspend(counter: counter)
    case .resume(let ns): next.resume(counter: counter, sleepNS: ns)
    }
    guard ok else { return false }
    guard writer.publish(next) else { snapshot = nil; return false }
    snapshot = next
    return true
  }
}
