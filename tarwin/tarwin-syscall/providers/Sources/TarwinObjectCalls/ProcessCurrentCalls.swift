import TarwinABI
import TarwinObject
import TarwinSyscall

public protocol CurrentProcessContext {
  /// Select only the scheduler's current process and hold its job, process
  /// and table writer locks for the call. A stopped caller has no context.
  mutating func withCaller<R>(_ body: (inout ProcessExecution, borrowing JobTree) -> R) -> R?
}

public struct ProcessCurrentCalls<C: CurrentProcessContext>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.processCurrent ? 0 : nil
  }
  public mutating func copyUserWords(
    from address: UInt64, into destination: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool { false }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.processCurrent else {
      return CallResult(status: syscallStatus(10, 1))
    }
    guard words.isEmpty else { return CallResult(status: syscallStatus(1, 1)) }
    guard let result = context.withCaller({ $0.currentHandle(tree: $1) }) else {
      return CallResult(status: syscallStatus(23, 1))
    }
    switch result {
    case .installed(let name): return CallResult(first: name)
    case .accessDenied: return CallResult(status: syscallStatus(4, 1))
    case .invalidHandle: return CallResult(status: syscallStatus(23, 1))
    case .limit: return CallResult(status: syscallStatus(33, 1))
    }
  }
}
