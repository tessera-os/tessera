public struct GuestTranslation {
  public let start: UInt64
  public let end: UInt64
  public let physical: UInt64
  public let flags: UInt64

  public init(start: UInt64, end: UInt64, physical: UInt64, flags: UInt64) {
    self.start = start
    self.end = end
    self.physical = physical
    self.flags = flags
  }
}
public struct GuestDomain {
  public let id: UInt64
  public let pageSize: UInt64
  public let maxMappings: Int
  public let ram: GuestAperture
  public internal(set) var maps: [GuestTranslation] = []

  public init(id: UInt64, pageSize: UInt64, maxMappings: Int, ram: GuestAperture) {
    self.id = id
    self.pageSize = pageSize
    self.maxMappings = maxMappings
    self.ram = ram
  }

  // Handle MAP and UNMAP on one existing attached domain. Endpoints and the
  // actual host IOMMU domain are fixed by the VM's DeviceSlot lease, never by
  // the domain number in the message. No BYPASS or MMIO mapping is advertised.
  public mutating func command(
    _ b: [UInt8],
    _ updateNestedAndInvalidate: ([GuestTranslation]) -> Bool
  ) -> UInt64 {
    if b.count < 8 || pageSize < 4096 || (pageSize & (pageSize - 1)) != 0 { return 4 }
    let op = b[0]
    if (op == 3 && b.count != 36) || (op == 4 && b.count != 28) { return 4 }
    if op != 3 && op != 4 { return 2 }
    if vword(b, 4, 4) != id { return 6 }
    let start = vword(b, 8, 8)
    let end = vword(b, 16, 8)
    if start > end || start % pageSize != 0 || end % pageSize != pageSize - 1 { return 5 }
    var next: [GuestTranslation] = []
    for m in maps {
      if start > m.end || m.start > end {
        next.append(m)
        continue
      }
      if op == 3 || m.start < start || end < m.end { return 5 }
    }
    if op == 3 {
      if maps.count >= maxMappings { return 8 }
      let physical = vword(b, 24, 8)
      let flags = vword(b, 32, 4)
      if flags == 0 || flags > 3 { return 4 }
      if physical % pageSize != 0 || end - start == 0xffff_ffff_ffff_ffff
        || !containsSpan(ram, physical, end - start + 1)
      {
        return 5
      }
      next.append(GuestTranslation(start: start, end: end, physical: physical, flags: flags))
    }
    if !updateNestedAndInvalidate(next) { return 3 }
    maps = next
    return 0
  }
}
