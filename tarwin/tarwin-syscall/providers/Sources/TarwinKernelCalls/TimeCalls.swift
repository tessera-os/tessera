import TarwinABI
import TarwinSyscall

/// A kernel clock source; nil denotes an unavailable clock, never zero time.
public protocol TimeCallClock {
  func read(clock: UInt32) -> UInt64?
}

/// Time.read delegates all five LibTessera clock selectors to its source.
public struct TimeCalls<C: TimeCallClock>: CallProvider {
  public let clock: C
  public init(clock: C) { self.clock = clock }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.timeRead ? 1 : nil
  }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool { false }
  public func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.timeRead else { return CallResult(status: syscallStatus(10, 1)) }
    guard words.count == 1, let selector = UInt32(exactly: words[0]), selector <= 4 else {
      return CallResult(status: syscallStatus(1, 1))
    }
    guard let value = clock.read(clock: selector) else {
      return CallResult(status: syscallStatus(23, 1))
    }
    return CallResult(first: value)
  }
}
