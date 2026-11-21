// Final 4 KiB user leaf in four- or five-level paging, default WB PAT.
public func x64UserPage(_ pa: UInt64, paBits: UInt8, write: Bool, execute: Bool) -> UInt64 {
  if paBits < 32 || paBits > 52 || (write && execute) || (pa & 4095) != 0
    || pa >= (UInt64(1) << UInt64(paBits))
  {
    return 0
  }
  let rw: UInt64 = write ? 2 : 0
  let nx: UInt64 = execute ? 0 : (UInt64(1) << 63)
  return pa | 5 | rw | nx
}

public func x64WalkIndex(_ va: UInt64, levelFromLeaf: UInt8, la57: Bool) -> UInt64 {
  if levelFromLeaf > 4 || (levelFromLeaf == 4 && !la57) { return 512 }
  return (va >> (12 + UInt64(levelFromLeaf) * 9)) & 511
}
