public enum WakeScope: Equatable {
  case system
  case device(UInt64)
}
public struct WakeHolder: Equatable {
  public let process: UInt64
  public let id: UInt64
  public let scope: WakeScope

  public init(process: UInt64, id: UInt64, scope: WakeScope) {
    self.process = process
    self.id = id
    self.scope = scope
  }
}

// Serialized with suspend admission. A process is the resolved owner, not
// a caller-selected billing id. Close and process teardown are idempotent.
public struct WakeLocks: Equatable {
  public let limit: Int
  public internal(set) var seq: UInt64 = 0
  public internal(set) var count: Int = 0
  public internal(set) var entries: [WakeHolder] = []
  public mutating func acquire(_ process: UInt64, _ scope: WakeScope, _ entitled: Bool) -> UInt64 {
    if !entitled || process == 0 || count >= limit || seq == 0xffff_ffff_ffff_ffff { return 0 }
    seq += 1
    let h = WakeHolder(process: process, id: seq, scope: scope)
    if count == entries.count { entries.append(h) } else { entries[count] = h }
    count += 1
    return seq
  }
  public mutating func release(_ process: UInt64, _ id: UInt64) -> Bool {
    for i in 0..<count {
      if entries[i].process == process && entries[i].id == id {
        count -= 1
        entries[i] = entries[count]
        return true
      }
    }
    return false
  }
  public mutating func dropProcess(_ process: UInt64) {
    var kept: Int = 0
    for i in 0..<count {
      if entries[i].process != process {
        entries[kept] = entries[i]
        kept += 1
      }
    }
    count = kept
  }
  public func preventsSleep(_ target: WakeScope) -> Bool {
    for i in 0..<count {
      if target == .system || entries[i].scope == .system || entries[i].scope == target {
        return true
      }
    }
    return false
  }

  public init(limit: Int) {
    self.limit = limit
  }
}

public struct WakePattern: Equatable {
  public let offset: Int
  public let data: [UInt8]
  public let mask: [UInt8]
  public func matches(_ packet: [UInt8]) -> Bool {
    if offset < 0 || offset > packet.count || data.count == 0 || data.count > 128
      || data.count != mask.count || data.count > packet.count - offset
    {
      return false
    }
    var significant = false
    for i in 0..<data.count {
      if mask[i] != 0 { significant = true }
      if ((packet[offset + i] ^ data[i]) & mask[i]) != 0 { return false }
    }
    return significant
  }

  public init(offset: Int, data: [UInt8], mask: [UInt8]) {
    self.offset = offset
    self.data = data
    self.mask = mask
  }
}
