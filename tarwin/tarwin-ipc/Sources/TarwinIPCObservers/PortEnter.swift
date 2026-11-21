import Synchronization
import TarwinIPC

public enum PortEnterDecision: Equatable {
  case ready, wouldSleep
  case error(UInt32)
}

public enum PortQueueEvent: Equatable {
  case readiness(UInt64, UInt32)
  case rearm(UInt64, PortOperation)
  case notifyPeer(UInt64, completion: Bool)
  case scheduleTurn(UInt64)
  case ringFailed(UInt64, UInt32)
}

/// Callbacks run under the port lock. Latch notifications or enqueue work;
/// do not re-enter a source or port. The submitting process below is fixed
/// at ring creation; resolve all operation handles in that process. On
/// capacity refusal, schedule another turn when backend capacity returns.
public protocol PortRingWork: PortNotifications {
  mutating func capture(
    process: UInt64, port: UInt64, record: borrowing RingRecord,
    queue: inout CompletionPort
  ) -> Bool
}

struct OwnedPortRings: ~Copyable {
  let owner: UInt64
  private var submissions: PortSubmissions
  private var completion: RingEndpoint
  init?(process: UInt64, words: UnsafeBufferPointer<Atomic<UInt32>>) {
    guard process != 0, let reader = PortSubmissions(fresh: words),
      let writer = RingEndpoint(fresh: words, completion: true, producer: true),
      reader.isPaired(with: writer)
    else { return nil }
    owner = process
    submissions = reader
    completion = writer
  }

  mutating func flush(
    port: UInt64, queue: inout CompletionPort, notify: (PortQueueEvent) -> Void
  ) -> UInt32 {
    var wake = false
    defer { if wake { notify(.notifyPeer(port, completion: true)) } }
    for _ in 0..<64 {
      switch queue.publishNext(to: &completion, rearm: { notify(.rearm(port, $0)) }) {
      case .transferred(let notify): wake = wake || notify
      case .wait, nil: return 0
      case .exhausted: return 33
      case .wrongSide, .invalidPeer: return 23
      }
    }
    if queue.available > 0 { notify(.scheduleTurn(port)) }
    switch queue.acknowledgeConsumed(
      from: &completion, armNotification: true,
      rearm: { notify(.rearm(port, $0)) })
    {
    case nil: return 0
    default: return 23
    }
  }

  mutating func turn<W: PortRingWork>(
    process: UInt64, port: UInt64, queue: inout CompletionPort, deadline: UInt64,
    now: UInt64, work: inout W
  ) -> PortEnterDecision {
    let before = flush(port: port, queue: &queue) { work.portEvent($0) }
    guard before == 0 else { return .error(before) }
    let submit = submissions.drain(budget: 64) { record in
      work.capture(process: process, port: port, record: record, queue: &queue)
    }
    if submit.notifyPeer { work.portEvent(.notifyPeer(port, completion: false)) }
    switch submit.stop {
    case .invalidPeer: return .error(23)
    case .exhausted: return .error(33)
    case .budget: work.portEvent(.scheduleTurn(port))
    case .capacity, .idle: break
    }
    let after = flush(port: port, queue: &queue) { work.portEvent($0) }
    guard after == 0 else { return .error(after) }
    if queue.readable { return .ready }
    if deadline != .max && now >= deadline { return .error(25) }
    return .wouldSleep
  }
}
