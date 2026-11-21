import TarwinABI
import TarwinObject
import TarwinSyscall

public protocol EventNamespace {
  /// Allocate fresh headers charged to the current caller's job. Under
  /// registry and table locks, publish the record only on success. Drop
  /// the creator references after the callback on either path.
  mutating func withNewEvent(
    pair: Bool, _ body: (inout EventEndpoints, inout HandleTable) -> CallResult
  ) -> CallResult
  /// Select and lock the candidate record and caller's table. A missing
  /// name returns InvalidHandle, a non-event WrongType. Notify observers
  /// in arming order before unlocking, without re-entering either lock.
  mutating func withEvent(
    named: UInt64,
    _ body: (borrowing EventEndpoints, borrowing HandleTable, (UnsafePointer<ObjectHeader>) -> Void)
      -> CallResult
  ) -> CallResult
}

public struct EventCalls<C: EventNamespace>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    switch number {
    case TarwinCall.eventCreate: 1
    case TarwinCall.eventPairCreate: 0
    case TarwinCall.objectSignal: 3
    default: nil
    }
  }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  private static func result(_ status: EventStatus, _ a: UInt64 = 0, _ b: UInt64 = 0) -> CallResult
  {
    let code: UInt32
    switch status {
    case .ok: return CallResult(first: a, second: b)
    case .invalidMask: code = 1
    case .invalidHandle: code = 2
    case .wrongType: code = 3
    case .denied: code = 4
    case .badState: code = 23
    case .peerClosed: code = 27
    case .limit: code = 33
    }
    return CallResult(status: syscallStatus(code, 1))
  }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard let count = argumentCount(for: number) else {
      return CallResult(status: syscallStatus(10, 1))
    }
    guard words.count == Int(count) else { return Self.result(.invalidMask) }
    if number == TarwinCall.objectSignal {
      guard let set = UInt32(exactly: words[1]), let clear = UInt32(exactly: words[2]) else {
        return Self.result(.invalidMask)
      }
      let name = words[0]
      return context.withEvent(named: name) { record, table, notify in
        Self.result(record.signal(name: name, set: set, clear: clear, in: table, notify: notify))
      }
    }
    let pair = number == TarwinCall.eventPairCreate
    guard let initial = UInt32(exactly: pair ? 0 : words[0]),
      initial & ~EventEndpoints.writableSignals == 0
    else { return Self.result(.invalidMask) }
    return context.withNewEvent(pair: pair) { record, table in
      guard record.paired == pair else { return Self.result(.badState) }
      let names = record.publish(initial: initial, in: &table)
      return Self.result(names.status, names.first, names.second)
    }
  }
}
