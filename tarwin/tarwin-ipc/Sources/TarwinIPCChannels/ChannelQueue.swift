import TarwinIPC
import TarwinObject

public enum ChannelStatus: Equatable {
  case ok, shouldWait, peerClosed, outOfRange, invalidHandle, accessDenied, handleLimit
  case bufferTooSmall(bytes: Int, handles: Int)
}

public struct ChannelSize: Equatable {
  public fileprivate(set) var bytes = 0
  public fileprivate(set) var handles = 0
  public init() {}
}

/// One FIFO for each direction of a channel pair. Hold the pair lock and
/// the relevant process's table writer lock in kernel lock order. Buffers
/// passed to read/write must already be pinned and disjoint from the queue.
public struct ChannelQueue: ~Copyable {
  public static var maxMessages: Int { 1024 }
  public static var maxBytes: Int { 4 * 1024 * 1024 }
  private let lengths: UnsafeMutableBufferPointer<ChannelSize>
  private let payload: UnsafeMutableRawBufferPointer
  private let grants: UnsafeMutableBufferPointer<ObjectGrant>
  private var first = 0, readOffset = 0
  public private(set) var count = 0, usedBytes = 0
  public private(set) var senderClosed = false, receiverClosed = false

  /// Lengths and bytes are initialized storage. Grant storage is uninitialized
  /// and holds exactly the slots for unread handles. Close the receiver before
  /// releasing any storage. Smaller channel quotas may be supplied by the job.
  public init?(
    lengths: UnsafeMutableBufferPointer<ChannelSize>,
    bytes: UnsafeMutableRawBufferPointer, grants: UnsafeMutableBufferPointer<ObjectGrant>
  ) {
    guard (1...Self.maxMessages).contains(lengths.count), (1...Self.maxBytes).contains(bytes.count),
      grants.count == lengths.count * 64, lengths.baseAddress != nil, bytes.baseAddress != nil,
      grants.baseAddress != nil
    else { return nil }
    self.lengths = lengths
    self.payload = bytes
    self.grants = grants
  }

  public var readable: Bool { count != 0 && !receiverClosed }
  public var writable: Bool {
    !senderClosed && !receiverClosed && count < lengths.count && usedBytes < payload.count
  }
  public var nextSize: ChannelSize? { readable ? lengths[first] : nil }

  public mutating func write(
    _ bytes: UnsafeRawBufferPointer, names: UnsafeBufferPointer<UInt64>,
    from table: inout HandleTable, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ChannelStatus {
    // The syscall boundary rejects an oversized handle list before copying it.
    guard names.count <= 64 else { return .outOfRange }
    let status: ChannelStatus
    if !channelMessageFits(UInt64(bytes.count), UInt64(names.count)) {
      status = .outOfRange
    } else if senderClosed || receiverClosed {
      status = .peerClosed
    } else if !writable || bytes.count > payload.count - usedBytes {
      status = .shouldWait
    } else {
      status = .ok
    }
    let slot = (first + count) % lengths.count
    var n = 0
    let result = table.moveForChannel(names) { (g: consuming ObjectGrant) in
      if status == .ok {
        (grants.baseAddress! + slot * 64 + n).initialize(to: g)
        n += 1
      } else {
        g.drop(retire: retire)
      }
    }
    switch result {
    case .accessDenied: return .accessDenied
    case .invalidHandle, .wrongType: return .invalidHandle
    case .allowed: break
    }
    guard status == .ok else { return status }
    if bytes.count != 0 {
      let at = (readOffset + usedBytes) % payload.count
      let leading = min(bytes.count, payload.count - at)
      (payload.baseAddress! + at).copyMemory(from: bytes.baseAddress!, byteCount: leading)
      if leading != bytes.count {
        payload.baseAddress!.copyMemory(
          from: bytes.baseAddress! + leading, byteCount: bytes.count - leading)
      }
    }
    lengths[slot].bytes = bytes.count
    lengths[slot].handles = n
    usedBytes += bytes.count
    count += 1
    return .ok
  }

  public mutating func read(
    into bytes: UnsafeMutableRawBufferPointer,
    names: UnsafeMutableBufferPointer<UInt64>, to table: inout HandleTable,
    size: inout ChannelSize
  ) -> ChannelStatus {
    size = ChannelSize()
    guard let next = nextSize else {
      return senderClosed || receiverClosed ? .peerClosed : .shouldWait
    }
    guard next.bytes <= bytes.count, next.handles <= names.count else {
      return .bufferTooSmall(bytes: next.bytes, handles: next.handles)
    }
    guard table.freeCount >= next.handles else { return .handleLimit }
    for i in 0..<next.handles {
      let g = (grants.baseAddress! + first * 64 + i).move()
      switch table.installMoved(g) {
      case .installed(let name): names[i] = name
      case .limit: preconditionFailure("handle table lock or free count invariant violated")
      }
    }
    if next.bytes != 0 {
      let leading = min(next.bytes, payload.count - readOffset)
      bytes.baseAddress!.copyMemory(from: payload.baseAddress! + readOffset, byteCount: leading)
      if leading != next.bytes {
        (bytes.baseAddress! + leading).copyMemory(
          from: payload.baseAddress!, byteCount: next.bytes - leading)
      }
    }
    size = next
    pop()
    return .ok
  }

  private mutating func pop() {
    let n = lengths[first].bytes
    usedBytes -= n
    readOffset = (readOffset + n) % payload.count
    first = (first + 1) % lengths.count
    count -= 1
  }

  // Reader can drain existing messages after observing peer closure.
  public mutating func closeSender() { senderClosed = true }

  public mutating func closeReceiver(retire: (UnsafePointer<ObjectHeader>) -> Void) {
    receiverClosed = true
    while count != 0 {
      for i in 0..<lengths[first].handles {
        (grants.baseAddress! + first * 64 + i).move().drop(retire: retire)
      }
      pop()
    }
  }
}
