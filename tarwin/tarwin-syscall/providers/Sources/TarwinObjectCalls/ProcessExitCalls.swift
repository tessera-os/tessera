import TarwinABI
import TarwinObject
import TarwinSyscall

public protocol ExitingProcessContext {
  /// Select the current process, not a handle supplied by the calling
  /// thread. Hold its job/task locks while queuing non-reentrant stop requests.
  mutating func withExitingCaller(
    _ body: (inout ProcessExecution, borrowing JobTree, (UInt64) -> Void) -> Bool
  ) -> Bool?
}

public struct ProcessExitCalls<C: ExitingProcessContext>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for n: UInt64) -> UInt32? { n == TarwinCall.processExit ? 1 : nil }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.processExit else { return CallResult(status: syscallStatus(10, 1)) }
    guard words.count == 1 else { return CallResult(status: syscallStatus(1, 1)) }
    let cause = TaskExit(.exited, code: Int64(bitPattern: words[0]))
    let stopping = context.withExitingCaller { process, tree, stop in
      process.exit != nil || process.requestExit(cause, tree: tree, stop: stop)
    }
    return stopping == true ? CallResult() : CallResult(status: syscallStatus(23, 1))
  }
}
