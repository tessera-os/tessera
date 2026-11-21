import TarwinABI
import TarwinIPCChannels
import TarwinObject
import TarwinSyscall

/// Resolve the candidate pair in the caller's namespace and hold the pair
/// lock and caller's table writer lock in kernel order across the body.
public protocol ChannelNamespace {
  mutating func withPair(
    named: UInt64, _ body: (inout ChannelPair, inout HandleTable) -> CallResult
  ) -> CallResult
}

/// Pin writable user pages, including COW resolution, before taking channel
/// or table locks. Invoke body once with disjoint nonfaulting kernel aliases,
/// or return nil without invoking it. Reject physical aliases as well as VA
/// overlap. An empty span needs no mapping.
public protocol ChannelUserOutput {
  var userRange: Range<UInt64> { get }
  mutating func withWritable(
    bytes: Range<UInt64>, names: Range<UInt64>,
    _ body: (UnsafeMutableRawBufferPointer, UnsafeMutableBufferPointer<UInt64>) -> CallResult
  ) -> CallResult?
}

private func failure(_ code: UInt32, detail: UInt64 = 0) -> CallResult {
  CallResult(status: syscallStatus(code, 1), detail: detail)
}

private func span(_ address: UInt64, _ count: UInt64, within range: Range<UInt64>) -> Range<UInt64>?
{
  if count == 0 { return 0..<0 }
  guard address != 0, range.contains(address), count <= range.upperBound - address else {
    return nil
  }
  return address..<(address + count)
}

public struct ChannelReceiveCalls<Space: ChannelNamespace, Memory: ChannelUserOutput>: CallProvider
{
  public var space: Space, memory: Memory
  public init(space: Space, memory: Memory) {
    self.space = space
    self.memory = memory
  }
  public func argumentCount(for number: UInt64) -> UInt32? {
    switch number {
    case TarwinCall.channelPeek: return 1
    case TarwinCall.channelRead: return 5
    default: return nil
    }
  }
  public func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    false
  }

  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard let count = argumentCount(for: number) else { return failure(10) }
    guard words.count == Int(count) else { return failure(1) }
    let name = words[0]
    if number == TarwinCall.channelPeek { return Self.access(name, space: &space, output: nil) }
    // The kernel cannot write more than one legal whole message.
    let byteCount = min(words[2], 65536)
    let nameCount = min(words[4], 64)
    guard nameCount == 0 || words[3] & 7 == 0,
      let bytes = span(words[1], byteCount, within: memory.userRange),
      let names = span(words[3], nameCount * 8, within: memory.userRange),
      !bytes.overlaps(names)
    else { return failure(1) }
    return memory.withWritable(bytes: bytes, names: names) { b, h in
      guard b.count == Int(byteCount), h.count == Int(nameCount) else { return failure(1) }
      return Self.access(name, space: &space, output: (b, h))
    } ?? failure(1)
  }

  private static func access(
    _ name: UInt64, space: inout Space,
    output: (UnsafeMutableRawBufferPointer, UnsafeMutableBufferPointer<UInt64>)?
  ) -> CallResult {
    space.withPair(named: name) { pair, table in
      switch table.reader.pinWithinEpoch(name, kind: TarwinKind.channel, need: 1 << 2) {
      case .invalidHandle: return failure(2)
      case .wrongType: return failure(3)
      case .accessDenied: return failure(4)
      case .found(let grant):
        let end = pair.end(of: grant.header)
        // The locked table still owns the source reference.
        grant.drop { _ in preconditionFailure("lost locked channel reference") }
        guard let end else { return failure(2) }
        var size = ChannelSize()
        let result: ChannelStatus
        if let (bytes, names) = output {
          result = pair.receive(at: end, into: bytes, names: names, table: &table, size: &size)
        } else {
          result = pair.peek(at: end, size: &size)
        }
        switch result {
        case .ok: return CallResult(first: UInt64(size.bytes), second: UInt64(size.handles))
        case .bufferTooSmall(let bytes, _): return failure(7, detail: UInt64(bytes))
        case .shouldWait: return failure(24)
        case .peerClosed: return failure(27)
        case .handleLimit: return failure(33)
        case .outOfRange: return failure(6)
        case .invalidHandle: return failure(2)
        case .accessDenied: return failure(4)
        }
      }
    }
  }
}
