public enum KernelCategory: UInt8 {
  case boot, sched, vm, alloc, ipc, loader, security, device, block, trfs, net, gpu, hypervisor,
    power, thermal, probe, panic
}
public enum TraceKind {
  case contextSwitch, wake, interrupt, syscall, fault, block, network, fence, power, userBegin,
    userEnd, userInstant, userCounter
}
public struct TraceRecord {
  public let monotonicNanos: UInt64
  public let kind: TraceKind
  public let subject: UInt64
  public let value: UInt64

  public init(monotonicNanos: UInt64, kind: TraceKind, subject: UInt64, value: UInt64) {
    self.monotonicNanos = monotonicNanos
    self.kind = kind
    self.subject = subject
    self.value = value
  }
}

public func logEnabled(_ level: UInt64, _ minimum: UInt64) -> Bool { return level >= minimum }

// One writer per ring (kernel CPU or user thread). The ring owner keeps 'produced'
// private. Accessors supply acquire/release and write the whole record before publication.
// The reader's ticket is untrusted: invalid cursors must not yield a writable pointer.
struct RingCursor {
  let capacity: UInt64
  var produced: UInt64 = 0
  var dropped: UInt64 = 0

  mutating func reserve(_ consumed: UInt64) -> UInt64? {
    if capacity < 64 || capacity > 65536 || (capacity & (capacity - 1)) != 0 || consumed > produced
      || produced - consumed >= capacity || produced == 0xffff_ffff_ffff_ffff
    {
      if dropped < 0xffff_ffff_ffff_ffff { dropped += 1 }
      return nil
    }
    return produced & (capacity - 1)
  }
  mutating func commit(_ releaseHead: (UInt64) -> Void) {
    produced += 1
    releaseHead(produced)
  }
}

public struct TraceProducer {
  private var cursor: RingCursor
  public var capacity: UInt64 { cursor.capacity }
  public var produced: UInt64 { cursor.produced }
  public var dropped: UInt64 { cursor.dropped }
  public init(capacity: UInt64) { cursor = RingCursor(capacity: capacity) }

  public mutating func push(
    _ record: TraceRecord, _ consumed: UInt64,
    _ store: (UInt64, TraceRecord) -> Void, _ releaseHead: (UInt64) -> Void
  ) -> Bool {
    guard let slot = cursor.reserve(consumed) else { return false }
    store(slot, record)
    cursor.commit(releaseHead)
    return true
  }
}

public enum CounterScope { case thread, process, system }
public func counterAccess(
  _ scope: CounterScope, _ targetOwner: UInt64, _ caller: UInt64, _ debugResource: Bool
) -> Bool {
  if scope == .system { return debugResource }
  return targetOwner != 0 && targetOwner == caller
}

public struct CounterSession {
  public let target: UInt64
  public internal(set) var hardware: UInt64 = 0
  public internal(set) var total: UInt64 = 0

  public init(target: UInt64) {
    self.target = target
  }

  public mutating func start(_ program: (UInt64) -> UInt64) -> Bool {
    if hardware != 0 { return false }
    hardware = program(target)
    return hardware != 0
  }
  public mutating func stop(_ disableReadAndRelease: (UInt64) -> UInt64) -> Bool {
    if hardware == 0 { return false }
    let delta = disableReadAndRelease(hardware)
    total = delta > 0xffff_ffff_ffff_ffff - total ? UInt64(0xffff_ffff_ffff_ffff) : total + delta
    hardware = 0
    return true
  }
}
