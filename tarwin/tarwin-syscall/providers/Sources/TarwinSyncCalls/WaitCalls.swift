import TarwinABI
import TarwinSync
import TarwinSyscall

public protocol PinnedWaitWord {
  var physical: WaitAddress { get }
  /// Non-faulting atomic acquire load of the previously validated width.
  func load() -> UInt64?
}

public protocol WaitCallContext {
  associatedtype Word: PinnedWaitWord
  /// Stable kernel storage, never a user pointer.
  var waits: UnsafePointer<AddressQueue> { get }
  var threadSlot: Int { get }
  /// Enforce the caller's user address range, read permission and width,
  /// and hold a frame pin through body. Resolve faults outside all wait locks.
  func withReadable<R>(_ address: UInt64, width: UInt32, _ body: (Word) -> R) -> R?
  /// Disable preemption and prevent interrupts taking a queue lock on this CPU;
  /// restore the previous state on return. Never covers a VM fault or park.
  func critical<R>(_ body: () -> R) -> R
  func monotonic() -> UInt64
  /// Resolve only a validated PI word to a live thread; ordinary words return 0.
  func owner(of: Word, ifEqualTo: UInt32) -> UInt64
  /// Commit scheduler state, retain/transfer/release frame pins, update PI,
  /// and arm/disarm this ticket's timer. Queues call this with their locks held.
  func change(_ event: AddressChange, deadline: UInt64)
  /// If already woken, consume the saved result rather than sleeping. No queue
  /// lock or temporary VM pin remains held. A timer expires via waits.finish.
  func park(_ ticket: SleepTicket) -> WaitEnd
}

public struct WaitCalls<C: WaitCallContext>: CallProvider {
  public let context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    switch number {
    case TarwinCall.syncWait32, TarwinCall.syncWait64: 3
    case TarwinCall.syncWake: 2
    case TarwinCall.syncRequeue: 4
    default: nil
    }
  }
  // All four private calls fit entirely in registers on every target.
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  private func error(_ c: UInt32) -> CallResult { CallResult(status: syscallStatus(c, 1)) }
  private func aligned(_ address: UInt64, _ width: UInt32) -> Bool {
    address != 0 && address % UInt64(width) == 0 && address <= UInt64.max - UInt64(width - 1)
  }
  public func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard let arity = argumentCount(for: number) else { return error(10) }
    guard words.count == Int(arity) else { return error(1) }
    let address = words[0]
    let width: UInt32 = number == TarwinCall.syncWait64 ? 8 : 4
    guard aligned(address, width) else { return error(1) }
    let q = context.waits
    switch number {
    case TarwinCall.syncWait32, TarwinCall.syncWait64:
      let expected = words[1]
      let deadline = words[2]
      guard width != 4 || expected <= UInt32.max else { return error(1) }
      let arm = context.withReadable(address, width: width) { word in
        context.critical {
          q.pointee.arm(
            slot: context.threadSlot, key: word.physical, width: width, expected: expected,
            deadline: deadline,
            owner: width == 4 ? context.owner(of: word, ifEqualTo: UInt32(expected)) : 0,
            load: word.load, now: context.monotonic,
            change: { context.change($0, deadline: deadline) })
        }
      }
      switch arm {
      case .none, .invalidArgument, .fault: return error(1)
      case .badState: return error(23)
      case .timeout: return error(25)
      case .blocked(let t):
        switch context.park(t) {
        case .woken: return CallResult()
        case .timeout: return error(25)
        case .cancelled: return error(26)
        }
      }
    case TarwinCall.syncWake:
      guard let count = UInt32(exactly: words[1]) else { return error(1) }
      return context.withReadable(address, width: 4) { word in
        guard
          let n = context.critical({
            q.pointee.wake(
              word.physical, count: count, change: { context.change($0, deadline: .max) })
          })
        else { return error(1) }
        return CallResult(first: UInt64(n))
      } ?? error(1)
    default:
      let target = words[2]
      guard aligned(target, 4), let wake = UInt32(exactly: words[1]),
        let move = UInt32(exactly: words[3])
      else { return error(1) }
      return context.withReadable(address, width: 4) { source in
        context.withReadable(target, width: 4) { dest in
          guard
            let n = context.critical({
              q.pointee.requeue(
                from: source.physical, wake: wake, to: dest.physical, move: move,
                change: { context.change($0, deadline: .max) })
            })
          else { return error(1) }
          return CallResult(first: UInt64(n.woken) + UInt64(n.moved))
        } ?? error(1)
      } ?? error(1)
    }
  }
}
