import TarwinABI
import TarwinRandomCore
import TarwinSyscall

public protocol KernelRandomCallContext {
  var userRange: Range<UInt64> { get }
  /// Under the RNG lock, read the trusted current epoch and fill exactly
  /// 32 bytes with KernelRandom.fill. Return that same epoch, or nil.
  mutating func freshSeed(into: UnsafeMutableRawBufferPointer) -> RandomEpoch?
  /// Unprivileged, fault-recoverable copy; the RNG lock is no longer held.
  mutating func copyOut(to: UInt64, from: UnsafeRawBufferPointer) -> Bool
}

/// The private Random.fill trap seeds a thread-local generator, not an
/// arbitrary-length write under the system RNG lock. See the public backend.
public struct RandomCalls<C: KernelRandomCallContext>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for n: UInt64) -> UInt32? { n == TarwinCall.randomFill ? 1 : nil }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.randomFill else { return .init(status: syscallStatus(10, 1)) }
    let r = context.userRange
    guard words.count == 1, r.contains(words[0]), r.upperBound - words[0] >= 32
    else { return .init(status: syscallStatus(1, 1)) }
    var seed = InlineArray<32, UInt8>(repeating: 0)
    return withUnsafeMutableBytes(of: &seed) { bytes in
      guard let e = context.freshSeed(into: bytes), e.available else {
        return .init(status: syscallStatus(23, 1))
      }
      guard context.copyOut(to: words[0], from: .init(bytes)) else {
        return .init(status: syscallStatus(1, 1))
      }
      switch e {
      case .physical: return .init()
      case .virtualMachine(let lo, let hi): return .init(first: lo, second: hi)
      }
    }
  }
}
