// One ledger per client Process. The driver charges a mapping once, not on
// every CPU or GPU view. Memory handles/allocations are resolved before use.
public enum GpuBacking: Equatable {
  case system
  case deviceLocal
}
public struct GpuCharge: Equatable {
  public let id: UInt64
  public let bytes: UInt64
  public let backing: GpuBacking

  public init(id: UInt64, bytes: UInt64, backing: GpuBacking) {
    self.id = id
    self.bytes = bytes
    self.backing = backing
  }
}
public struct GpuFootprint: Equatable {
  public let process: UInt64
  public let limit: UInt64
  public let objectLimit: Int
  public internal(set) var used: UInt64 = 0
  public internal(set) var count: Int = 0
  public internal(set) var entries: [GpuCharge] = []

  public mutating func charge(_ client: UInt64, _ allocation: GpuCharge) -> Bool {
    if process == 0 || client != process || allocation.id == 0 || allocation.bytes == 0
      || count >= objectLimit || used > limit || allocation.bytes > limit - used
    {
      return false
    }
    for i in 0..<count { if entries[i].id == allocation.id { return false } }
    if count < entries.count { entries[count] = allocation } else { entries.append(allocation) }
    count += 1
    used += allocation.bytes
    return true
  }

  // Release only after the memory manager has drained DMA and mappings.
  public mutating func release(_ client: UInt64, _ id: UInt64, _ retired: (UInt64) -> Bool) -> Bool
  {
    if client != process { return false }
    for i in 0..<count {
      if entries[i].id == id {
        if !retired(id) { return false }
        used -= entries[i].bytes
        count -= 1
        entries[i] = entries[count]
        return true
      }
    }
    return false
  }

  public init(process: UInt64, limit: UInt64, objectLimit: Int) {
    self.process = process
    self.limit = limit
    self.objectLimit = objectLimit
  }
}
