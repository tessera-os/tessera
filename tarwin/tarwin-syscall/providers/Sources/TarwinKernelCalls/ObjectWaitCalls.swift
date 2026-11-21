import TarwinABI
import TarwinObject
import TarwinSync
import TarwinSyncCalls
import TarwinSyscall

/// Resolve with Wait rights and hold the signal lock through the callback.
public protocol ObjectWaitContext: WaitQueueContext {
  /// Separate from physical-address waits: object koids are a different key space.
  var objectWaits: UnsafePointer<AddressQueue> { get }
  /// Transfer a pin to the wait only when body returns blocked; release on ready.
  func withWaitObject(name: UInt64, mask: UInt32,
    _ body: (UnsafePointer<ObjectHeader>) -> SplitWaitResult) -> SplitWaitResult
  func observed(_ ticket: SleepTicket) -> UInt32
}

/// Native callers can keep the stack parked until the ticket completes.
public protocol ObjectWaitParkContext: ObjectWaitContext {
  func park(_ ticket: SleepTicket) -> WaitEnd
}

/// Object.wait is a synchronous ABI call with a non-parking kernel entry.
public struct ObjectWaitCalls<C: ObjectWaitContext> {
  public let context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.objectWait ? 3 : nil
  }
  public func begin(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> SplitWaitResult {
    guard number == TarwinCall.objectWait else {
      return .completed(CallResult(status: syscallStatus(10, 1)))
    }
    guard words.count == 3, let mask = UInt32(exactly: words[1]), mask != 0 else {
      return .completed(CallResult(status: syscallStatus(1, 1)))
    }
    let deadline = words[2]
    return context.withWaitObject(name: words[0], mask: mask) { object in
      let signals = object.pointee.signals
      if signals & mask != 0 { return .completed(CallResult(first: UInt64(signals))) }
      let result = context.objectWaits.pointee.arm(slot: context.threadSlot,
        key: WaitAddress(frame: object.pointee.koid, offset: 0), width: 4,
        expected: UInt64(signals), deadline: deadline,
        load: { UInt64(object.pointee.signals) }, now: context.monotonic,
        change: { context.change($0, deadline: deadline) })
      switch result {
      case .blocked(let ticket): return .blocked(ticket)
      case .timeout: return .completed(CallResult(status: syscallStatus(25, 1)))
      case .badState: return .completed(CallResult(status: syscallStatus(23, 1)))
      case .invalidArgument, .fault: return .completed(CallResult(status: syscallStatus(1, 1)))
      }
    }
  }
  public func complete(_ ticket: SleepTicket, reason: WaitEnd) -> CallResult {
    let result = waitCallCompletion(reason)
    return CallResult(status: result.status, first: UInt64(context.observed(ticket)))
  }
}

extension ObjectWaitCalls: CallProvider where C: ObjectWaitParkContext {
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool { false }
  public func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    switch begin(number: number, words: words) {
    case .completed(let result): return result
    case .blocked(let ticket): return complete(ticket, reason: context.park(ticket))
    }
  }
}
