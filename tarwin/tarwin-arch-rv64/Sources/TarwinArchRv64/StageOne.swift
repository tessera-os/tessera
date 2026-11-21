// Ordinary Sv48/Sv57 final-level user leaf: PBMT=PMA, N=0. Start with
// A/D clear so the MM can account for first access and first write.
public func rvUserPage(_ pa: UInt64, write: Bool, execute: Bool) -> UInt64 {
  if (write && execute) || (pa & 4095) != 0 || pa >= (UInt64(1) << 56) { return 0 }
  let w: UInt64 = write ? 4 : 0
  let x: UInt64 = execute ? 8 : 0
  return ((pa >> 12) << 10) | 0x13 | w | x
}

public func rvWalkIndex(_ va: UInt64, levelFromLeaf: UInt8, sv57: Bool) -> UInt64 {
  if levelFromLeaf > 4 || (levelFromLeaf == 4 && !sv57) { return 512 }
  return (va >> (12 + UInt64(levelFromLeaf) * 9)) & 511
}
