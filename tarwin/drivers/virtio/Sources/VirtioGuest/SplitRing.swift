// Virtio 1.2 split rings. The transport provides little-endian accesses to
// pinned DMA memory, including cache maintenance and acquire/release barriers.
// The driver serializes submit and consume for each queue.
public struct Segment: Equatable {
  public let iova: UInt64
  public let length: UInt32
  public let deviceWrites: Bool

  public init(iova: UInt64, length: UInt32, deviceWrites: Bool) {
    self.iova = iova
    self.length = length
    self.deviceWrites = deviceWrites
  }
}
struct DescriptorOwner: Equatable {
  var used: Bool
  var head: Int
  var next: Int
}
struct Submission: Equatable {
  var live: Bool
  var cookie: UInt64
  var writable: UInt32
}
public struct UsedBuffer: Equatable {
  public let cookie: UInt64
  public let written: UInt32

  public init(cookie: UInt64, written: UInt32) {
    self.cookie = cookie
    self.written = written
  }
}
public enum UsedResult: Equatable {
  case empty
  case broken
  case completed(UsedBuffer)
}
public struct SplitQueue: Equatable {
  public internal(set) var size: Int = 0
  public internal(set) var published: UInt16 = 0
  public internal(set) var consumed: UInt16 = 0
  public internal(set) var outstanding: Int = 0
  public internal(set) var broken: Bool = false
  var owners: [DescriptorOwner] = []
  var requests: [Submission] = []

  public mutating func initialize(_ count: Int) -> Bool {
    if size != 0 || count < 1 || count > 32768 || (count & (count - 1)) != 0 { return false }
    size = count
    for _ in 0..<count {
      owners.append(DescriptorOwner(used: false, head: -1, next: -1))
      requests.append(Submission(live: false, cookie: 0, writable: 0))
    }
    return true
  }

  public mutating func submit(
    _ cookie: UInt64, _ parts: [Segment],
    _ descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void,
    _ putAvailable: (Int, UInt16) -> Void, _ releaseAvailable: (UInt16) -> Void
  ) -> Bool {
    if broken || size == 0 || parts.count == 0 || parts.count > size { return false }
    var writable: UInt32 = 0
    var total: UInt64 = 0
    var sawWrite = false
    for part in parts {
      if part.length == 0 || UInt64(part.length - 1) > 0xffff_ffff_ffff_ffff - part.iova {
        return false
      }
      total += UInt64(part.length)
      if total > 0xffff_ffff { return false }
      if part.deviceWrites {
        writable += part.length
        sawWrite = true
      } else if sawWrite {
        return false
      }
    }
    var slots: [Int] = []
    for i in 0..<size {
      if !owners[i].used { slots.append(Int(i)) }
      if slots.count == parts.count { break }
    }
    if slots.count != parts.count { return false }
    let head = slots[0]
    for i in 0..<slots.count {
      let slot = slots[i]
      let part = parts[i]
      var flags: UInt16 = part.deviceWrites ? 2 : 0
      var next: Int = -1
      if i + 1 < slots.count {
        next = slots[i + 1]
        flags |= 1
      }
      owners[slot] = DescriptorOwner(used: true, head: head, next: next)
      descriptor(slot, part.iova, part.length, flags, next < 0 ? UInt16(0) : UInt16(next))
    }
    requests[head] = Submission(live: true, cookie: cookie, writable: writable)
    outstanding += 1
    putAvailable(Int(published) % size, UInt16(head))
    published = (published &+ 1)
    releaseAvailable(published)
    return true
  }

  // Read used.idx with acquire before reading the corresponding used entry.
  // Never trust the device's descriptor chain when recycling ownership.
  public mutating func consume(
    _ acquireUsed: () -> UInt16, _ usedId: (Int) -> UInt32, _ usedLength: (Int) -> UInt32
  ) -> UsedResult {
    if broken || size == 0 { return .broken }
    let delta = (acquireUsed() &- consumed)
    if delta == 0 { return .empty }
    if Int(delta) > outstanding {
      broken = true
      return .broken
    }
    let ringSlot = Int(consumed) % size
    let id = usedId(ringSlot)
    if id >= UInt32(size) {
      broken = true
      return .broken
    }
    let head = Int(id)
    let request = requests[head]
    let written = usedLength(ringSlot)
    if !request.live || written > request.writable {
      broken = true
      return .broken
    }
    var slot = head
    while slot >= 0 {
      let next = owners[slot].next
      owners[slot].used = false
      slot = next
    }
    requests[head].live = false
    consumed = consumed &+ 1
    outstanding -= 1
    return .completed(UsedBuffer(cookie: request.cookie, written: written))
  }

  public init() {
  }
}

public func isolatedSplitFeatures(_ offered: UInt64, _ supportedDeviceBits: UInt32) -> UInt64 {
  let mandatory: UInt64 = 0x3_0000_0000
  if (offered & mandatory) != mandatory { return 0 }
  return mandatory | (offered & UInt64(supportedDeviceBits) & 0xffffff)
}
