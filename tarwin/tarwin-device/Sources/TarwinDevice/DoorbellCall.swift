import TarwinABI
import TarwinSyscall

func doorbellError(_ code: UInt32) -> CallResult {
  CallResult(status: syscallStatus(code, 5))
}

public struct DoorbellGrantQuery {
  let range: UInt64, target: UInt64, offset: UInt64
}

public protocol DoorbellCallContext {
  mutating func withLockedCaller(_ query: DoorbellGrantQuery) -> CallResult
}

/// MmioRange.grantDoorbell(range handle, process handle, byte offset).
public struct DoorbellGrantCall<C: DoorbellCallContext>: CallProvider {
  public var context: C
  public init(_ context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.mmioRangeGrantDoorbell ? 3 : nil
  }
  public mutating func copyUserWords(
    from address: UInt64, into words: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool { false }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.mmioRangeGrantDoorbell else { return doorbellError(10) }
    guard words.count == 3 else { return doorbellError(1) }
    return context.withLockedCaller(
      DoorbellGrantQuery(range: words[0], target: words[1], offset: words[2]))
  }
}
