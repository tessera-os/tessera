import TarwinABI
import TarwinObject
import TarwinSyscall

/// Allocate a charged channel pair; hold registry/table locks through publication.
public protocol ChannelCreateContext {
  mutating func withNewChannel(
    _ body: (UnsafePointer<ObjectHeader>, UnsafePointer<ObjectHeader>, inout HandleTable) -> CallResult
  ) -> CallResult
}

/// Publish both endpoints atomically, retaining creator references in the registry.
public struct ChannelCreateCalls<C: ChannelCreateContext>: CallProvider {
  public var context: C
  public init(context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.channelCreate ? 1 : nil
  }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool { false }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.channelCreate else { return CallResult(status: syscallStatus(10, 1)) }
    guard words.count == 1, words[0] == 0 else { return CallResult(status: syscallStatus(1, 1)) }
    return context.withNewChannel { a, b, table in
      guard a != b, a.pointee.kind == TarwinKind.channel, b.pointee.kind == TarwinKind.channel,
        a.pointee.ownerJob == b.pointee.ownerJob else {
        return CallResult(status: syscallStatus(23, 1))
      }
      guard table.freeCount >= 2 else { return CallResult(status: syscallStatus(33, 1)) }
      switch table.install(a, rights: a.pointee.maximumRights) {
      case .installed(let first):
        switch table.install(b, rights: b.pointee.maximumRights) {
        case .installed(let second): return CallResult(first: first, second: second)
        default:
          _ = table.close(first) { _ in }
          return CallResult(status: syscallStatus(23, 1))
        }
      default: return CallResult(status: syscallStatus(23, 1))
      }
    }
  }
}
