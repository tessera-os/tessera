import TarwinABI
import TarwinIPCChannels
import TarwinObject
import TarwinObjectCalls
import TarwinSyscall

/// Capture names in immutable kernel storage, then the payload, before
/// taking either lock. Never pass mutable user aliases. If names cannot be
/// captured, return nil before body; a later payload fault passes nil data.
/// A nil requested span means the caller already rejected the payload.
public protocol ChannelUserInput {
  var userRange: Range<UInt64> { get }
  mutating func withCaptured(
    names: Range<UInt64>, bytes: Range<UInt64>?,
    _ body: (UnsafeBufferPointer<UInt64>, UnsafeRawBufferPointer?) -> CallResult
  ) -> CallResult?
}

public struct ChannelWriteCalls<S: ChannelNamespace, M: ChannelUserInput, L: HandleRetirement>:
  CallProvider
{
  public var space: S, memory: M, lifecycle: L
  public init(space: S, memory: M, lifecycle: L) {
    self.space = space
    self.memory = memory
    self.lifecycle = lifecycle
  }
  public func argumentCount(for n: UInt64) -> UInt32? { n == TarwinCall.channelWrite ? 5 : nil }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.channelWrite else { return failure(10) }
    guard words.count == 5 else { return failure(1) }
    let channel = words[0]
    let length = words[2]
    let count = words[4]
    guard count <= 64 else { return failure(6) }
    guard count == 0 || words[3] & 7 == 0,
      let names = span(words[3], count * 8, within: memory.userRange)
    else { return failure(1) }
    let bytes = length <= 65536 ? span(words[1], length, within: memory.userRange) : nil
    return memory.withCaptured(names: names, bytes: bytes) { handles, data in
      guard handles.count == Int(count) else { return failure(1) }
      return space.withPair(named: channel) { pair, table in
        switch resolveEnd(channel, need: 1 << 3, pair: pair, table: table) {
        case .denied(let code): return failure(code)
        case .found(let end):
          // Reject the sending endpoint itself, even under a duplicate name.
          for name in handles {
            switch table.reader.pinWithinEpoch(name, kind: 0, need: 2) {
            case .accessDenied: return failure(4)
            case .invalidHandle: return failure(2)
            case .wrongType: return failure(2)
            case .found(let grant):
              let isSender = pair.end(of: grant.header) == end
              grant.drop { _ in preconditionFailure("lost locked transfer reference") }
              if isSender { return failure(1) }
            }
          }
          if bytes != nil, let data, UInt64(data.count) == length {
            return channelResult(
              pair.send(
                from: end, data, names: handles, table: &table,
                invalidate: { lifecycle.invalidate($0) }, retire: { lifecycle.retire($0) }))
          }
          // Even a failed write consumes transferable handles, but never
          // part of an invalid list. moveForChannel rechecks duplicates.
          switch table.moveForChannel(
            handles, invalidate: { lifecycle.invalidate($0) },
            take: {
              (g: consuming ObjectGrant) in g.drop { lifecycle.retire($0) }
            })
          {
          case .allowed: return failure(length > 65536 ? 6 : 1)
          case .accessDenied: return failure(4)
          case .invalidHandle, .wrongType: return failure(2)
          }
        }
      }
    } ?? failure(1)
  }
}
