import TarwinObject

public enum ChannelEnd { case a, b }

/// The owner serializes pair operations and keeps both distinct headers
/// mapped for the pair's lifetime. Retire callbacks only enqueue destruction:
/// they must not synchronously reacquire process or channel locks.
public struct ChannelPair: ~Copyable {
  private var toA: ChannelQueue, toB: ChannelQueue
  private let a: UnsafePointer<ObjectHeader>, b: UnsafePointer<ObjectHeader>

  public init?(
    a: UnsafePointer<ObjectHeader>, b: UnsafePointer<ObjectHeader>,
    toA: consuming ChannelQueue, toB: consuming ChannelQueue
  ) {
    guard a != b, a.pointee.kind == TarwinKind.channel, b.pointee.kind == TarwinKind.channel else {
      return nil
    }
    self.a = a
    self.b = b
    self.toA = toA
    self.toB = toB
    refresh()
  }

  public func peek(at end: ChannelEnd) -> ChannelSize? {
    end == .a ? toA.nextSize : toB.nextSize
  }

  public mutating func send(
    from end: ChannelEnd, _ bytes: UnsafeRawBufferPointer,
    names: UnsafeBufferPointer<UInt64>, table: inout HandleTable,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ChannelStatus {
    let result: ChannelStatus
    switch end {
    case .a: result = toB.write(bytes, names: names, from: &table, retire: retire)
    case .b: result = toA.write(bytes, names: names, from: &table, retire: retire)
    }
    refresh()
    return result
  }

  public mutating func receive(
    at end: ChannelEnd, into bytes: UnsafeMutableRawBufferPointer,
    names: UnsafeMutableBufferPointer<UInt64>, table: inout HandleTable, size: inout ChannelSize
  ) -> ChannelStatus {
    let result: ChannelStatus
    switch end {
    case .a: result = toA.read(into: bytes, names: names, to: &table, size: &size)
    case .b: result = toB.read(into: bytes, names: names, to: &table, size: &size)
    }
    refresh()
    return result
  }

  public mutating func close(_ end: ChannelEnd, retire: (UnsafePointer<ObjectHeader>) -> Void) {
    switch end {
    case .a:
      toA.closeReceiver(retire: retire)
      toB.closeSender()
    case .b:
      toB.closeReceiver(retire: retire)
      toA.closeSender()
    }
    refresh()
  }

  private func refresh() {
    set(a, incoming: toA, outgoing: toB)
    set(b, incoming: toB, outgoing: toA)
  }

  private func set(
    _ header: UnsafePointer<ObjectHeader>, incoming: borrowing ChannelQueue,
    outgoing: borrowing ChannelQueue
  ) {
    let state: UInt32 =
      (incoming.readable ? 1 : 0) | (outgoing.writable ? 2 : 0) | (incoming.senderClosed ? 4 : 0)
    if header.pointee.signals & 7 != state {
      _ = header.pointee.updateSignals(clear: 7, set: state)
    }
  }
}
