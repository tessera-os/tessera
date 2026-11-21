import KCore

// One aligned 64-page leaf of the physical allocator. Each order-n block
// is the union of two aligned order-(n-1) buddies. Occupancy is stored
// only at the leaves: clearing a block immediately coalesces free buddies.
// A caller serializes access and supplies backing pages from validated RAM.
public struct PageArena {
  public internal(set) var base: UInt64
  public internal(set) var pageSize: UInt64
  public internal(set) var usable: UInt64
  public internal(set) var occupied: UInt64
  public internal(set) var starts: UInt64
  public internal(set) var ends: UInt64
}

public func makeArena(_ base: UInt64, pageSize: UInt64, usable: UInt64) -> PageArena {
  var eligible = usable
  if (pageSize != 4096 && pageSize != 16384) || !alignedTo(base, alignment: pageSize * 64)
    || !validExtent(base, length: pageSize * 64)
  {
    eligible = 0
  }
  return PageArena(
    base: base, pageSize: pageSize, usable: eligible, occupied: 0, starts: 0, ends: 0)
}

func pageMask(_ pages: UInt64) -> UInt64 {
  if pages == 64 { return 0xffff_ffff_ffff_ffff }
  return (UInt64(1) << pages) - 1
}

public struct Allocation {
  public internal(set) var ok: Bool
  public internal(set) var address: UInt64
}

public func takePages(_ arena: inout PageArena, order: UInt8) -> Allocation {
  if order <= 6 {
    let pages = UInt64(1) << UInt64(order)
    var index: UInt64 = 0
    while index < 64 {
      let mask = pageMask(pages) << index
      if (arena.usable & mask) == mask && (arena.occupied & mask) == 0 {
        arena.occupied = arena.occupied | mask
        arena.starts = arena.starts | (UInt64(1) << index)
        arena.ends = arena.ends | (UInt64(1) << (index + pages - 1))
        return Allocation(ok: true, address: arena.base + index * arena.pageSize)
      }
      index += pages
    }
  }
  return Allocation(ok: false, address: 0)
}

public func givePages(_ arena: inout PageArena, address: UInt64, order: UInt8) -> Bool {
  if order > 6 || address < arena.base || arena.usable == 0
    || !alignedTo(address, alignment: arena.pageSize)
  {
    return false
  }
  let index = (address - arena.base) / arena.pageSize
  let pages = UInt64(1) << UInt64(order)
  if index >= 64 || !alignedTo(index, alignment: pages) { return false }
  let mask = pageMask(pages) << index
  if (arena.occupied & mask) != mask || (arena.starts & mask) != UInt64(1) << index
    || (arena.ends & mask) != UInt64(1) << (index + pages - 1)
  {
    return false
  }
  arena.occupied = arena.occupied ^ mask
  arena.starts = arena.starts ^ (UInt64(1) << index)
  arena.ends = arena.ends ^ (UInt64(1) << (index + pages - 1))
  return true
}
