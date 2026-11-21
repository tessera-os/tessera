import Synchronization
import TarwinABI
import TarwinIPC
import TarwinObject
import TarwinSyscall

/// A port's pinned registry entry. Keep the slab and header mapped until
/// final destruction and the last reader epoch; never rebind either one.
public struct PortObject: ~Copyable {
  public let header: UnsafePointer<ObjectHeader>
  fileprivate var queue: CompletionPort
  private var published = false
  private var rings: OwnedPortRings?
  public static var initialRights: UInt64 { 0x7cf }

  public init?(header: UnsafePointer<ObjectHeader>, storage: UnsafeMutableBufferPointer<PortSlot>) {
    guard header.pointee.kind == TarwinKind.port,
      header.pointee.maximumRights == Self.initialRights,
      let queue = CompletionPort(storage: storage)
    else { return nil }
    self.header = header
    self.queue = queue
  }

  fileprivate mutating func publish(in table: inout HandleTable) -> CallResult {
    guard !published, !queue.closed else { return portError(23) }
    switch table.install(header, rights: Self.initialRights) {
    case .installed(let name):
      published = true
      return CallResult(first: name)
    case .limit: return portError(33)
    default: return portError(23)
    }
  }

  /// Before publishing the port, MM must exclusively pin this fresh,
  /// quiescent mapping for this process until final port retirement.
  public mutating func bindFreshRing(process: UInt64, words: UnsafeBufferPointer<Atomic<UInt32>>)
    -> Bool
  {
    guard !published, !queue.closed, rings == nil,
      let binding = OwnedPortRings(process: process, words: words)
    else { return false }
    rings = consume binding
    return true
  }

  /// Hold the port, mapping and caller table locks. If the result is
  /// wouldSleep, enroll under this same port lock before releasing it.
  /// Never install this as a blocking call without a resumable park path.
  public mutating func prepareEnter<W: PortRingWork>(
    name: UInt64, process: UInt64, table: borrowing HandleTable, deadline: UInt64,
    now: UInt64, work: inout W
  ) -> PortEnterDecision {
    let code = authorize(name, need: 128, table: table)
    guard code == 0 else { return .error(code) }
    guard rings != nil else { return .error(10) }
    guard rings?.owner == process else { return .error(4) }
    defer { recordReadiness { work.portEvent($0) } }
    return rings!.turn(
      process: process, port: header.pointee.koid, queue: &queue,
      deadline: deadline, now: now, work: &work)
  }

  fileprivate func authorize(_ name: UInt64, need: UInt64, table: borrowing HandleTable) -> UInt32 {
    switch table.reader.pinWithinEpoch(name, kind: TarwinKind.port, need: need) {
    case .invalidHandle: return 2
    case .wrongType: return 3
    case .accessDenied: return 4
    case .found(let grant):
      let matches = published && !queue.closed && header == grant.header
      grant.drop { _ in preconditionFailure("lost locked port reference") }
      return matches ? 0 : 2
    }
  }

  /// Serialize with arming and signal delivery. Record a transition in FIFO
  /// order; do not run an observer that locks a destination port here (the
  /// observer may target this same port). One logical operation per body.
  public mutating func withQueue<R>(
    notify: (PortQueueEvent) -> Void, _ body: (inout CompletionPort) -> R
  ) -> R {
    let result = body(&queue)
    let id = header.pointee.koid
    if !queue.closed, rings != nil {
      let code = rings!.flush(port: id, queue: &queue, notify: notify)
      if code != 0 { notify(.ringFailed(id, code)) }
    }
    recordReadiness(notify)
    return result
  }

  private func recordReadiness(_ notify: (PortQueueEvent) -> Void) {
    let old = header.pointee.signals
    let new = queue.readable ? old | 1 : old & ~1
    if new != old {
      _ = header.pointee.updateSignals(clear: 1, set: new & 1)
      notify(.readiness(header.pointee.koid, new))
    }
  }
}

/// Queue scheduler/provider work; neither callback may re-enter the port.
public protocol PortNotifications {
  mutating func portEvent(_ event: PortQueueEvent)
  mutating func wakeOne(port: UInt64)
  mutating func scheduleCancel(port: UInt64, source: UInt64, operation: PortOperation)
}

public protocol PortNamespace {
  associatedtype Notifications: PortNotifications
  /// Allocate and charge a fresh port to the caller's job, then hold the
  /// registry/table locks until publication commits or rolls back.
  mutating func withNewPort(_ body: (inout PortObject, inout HandleTable) -> CallResult)
    -> CallResult
  /// Select a candidate by name. Hold its port and caller's table locks
  /// across the callback; the final operand is monotonic kernel time.
  mutating func withPort(
    named: UInt64,
    _ body: (
      inout PortObject, borrowing HandleTable, inout Notifications, UInt64
    ) -> CallResult
  ) -> CallResult
  var userRange: Range<UInt64> { get }
  /// Fault-recoverable copy, before acquiring the port or table lock.
  mutating func readWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool
}

private func portError(_ code: UInt32) -> CallResult { CallResult(status: syscallStatus(code, 1)) }

public struct PortCalls<C: PortNamespace>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    switch number {
    case TarwinCall.portCreate: return 1
    case TarwinCall.portPost, TarwinCall.portCancel: return 2
    default: return nil
    }
  }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }

  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard let n = argumentCount(for: number) else { return portError(10) }
    guard words.count == Int(n) else { return portError(1) }
    let name = words[0]
    if number == TarwinCall.portCreate {
      guard name == 0 else { return portError(1) }
      return context.withNewPort { $0.publish(in: &$1) }
    }
    var packet = PortPacket()
    if number == TarwinCall.portPost {
      let range = context.userRange
      guard syscallTailInRange(words[1], 64, range.lowerBound, range.upperBound) else {
        return portError(1)
      }
      var raw = InlineArray<8, UInt64>(repeating: 0)
      guard
        withUnsafeMutableBytes(
          of: &raw, { context.readWords(from: words[1], into: $0.bindMemory(to: UInt64.self)) })
      else { return portError(1) }
      packet.key = raw[0]
      packet.error = UInt32(truncatingIfNeeded: raw[1])
      packet.subsystem = UInt16(truncatingIfNeeded: raw[1] >> 32)
      packet.errorFlags = UInt16(truncatingIfNeeded: raw[1] >> 48)
      packet.detail = raw[2]
      packet.flags = UInt32(raw[3] >> 32)
      packet.result0 = raw[4]
      packet.result1 = raw[5]
      packet.aux = raw[6]
    }
    return context.withPort(named: name) { entry, table, work, now in
      let post = number == TarwinCall.portPost
      let status = entry.authorize(name, need: post ? 8 : 0, table: table)
      guard status == 0 else { return portError(status) }
      let id = entry.header.pointee.koid
      if post {
        packet.timestamp = now
        guard
          entry.withQueue(
            notify: { work.portEvent($0) },
            { $0.post(packet) })
        else { return portError(24) }
        work.wakeOne(port: id)
        return CallResult()
      }
      let count = entry.queue.cancelWithSource(key: words[1]) { source, op in
        work.scheduleCancel(port: id, source: source, operation: op)
      }
      return CallResult(first: UInt64(count))
    }
  }
}
