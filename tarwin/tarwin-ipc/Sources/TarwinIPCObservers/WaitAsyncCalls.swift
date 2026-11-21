import TarwinABI
import TarwinObject
import TarwinSyscall

public protocol SignalCaller {
  associatedtype Ports: SignalPorts
  /// Use the current task's identity and locked table, the selected object's
  /// locked observer list, and the kernel monotonic clock, not user operands.
  mutating func withObservers(
    source: UInt64,
    _ body: (UInt64, borrowing HandleTable, inout SignalObservers, inout Ports, UInt64) ->
      SignalArmResult
  ) -> SignalArmResult
}

public struct WaitAsyncCalls<C: SignalCaller>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for n: UInt64) -> UInt32? { n == TarwinCall.objectWaitAsync ? 5 : nil }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.objectWaitAsync else {
      return CallResult(status: syscallStatus(10, 1))
    }
    guard words.count == 5, let mask = UInt32(exactly: words[1]), mask != 0,
      let raw = UInt32(exactly: words[2]), let mode = SignalWaitMode(rawValue: raw)
    else { return CallResult(status: syscallStatus(1, 1)) }
    let result = context.withObservers(source: words[0]) { process, table, observers, ports, now in
      observers.arm(
        process: process, source: words[0], mask: mask, mode: mode,
        destination: words[3], key: words[4], table: table, at: now, ports: &ports)
    }
    let code: UInt32
    switch result {
    case .armed: return CallResult()
    case .invalidArgument: code = 1
    case .invalidHandle: code = 2
    case .wrongType: code = 3
    case .denied: code = 4
    case .limit: code = 33
    }
    return CallResult(status: syscallStatus(code, 1))
  }
}
