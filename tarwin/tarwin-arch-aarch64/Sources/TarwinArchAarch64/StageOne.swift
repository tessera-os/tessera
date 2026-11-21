// EL1&0 stage-1 final-level user page, 16 KiB granule, 48-bit output
// addresses, MAIR index 0 = normal WB. Reject LPA2 rather than ignoring
// descriptor bits repurposed by that translation regime.
public func armUserPage(_ pa: UInt64, write: Bool, execute: Bool, lpa2: Bool) -> UInt64 {
  if lpa2 || (write && execute) || (pa & 0x3fff) != 0 || pa >= (UInt64(1) << 48) { return 0 }
  let ap: UInt64 = write ? 0x40 : 0xc0
  let uxn: UInt64 = execute ? 0 : (UInt64(1) << 54)
  return pa | 3 | ap | 0x300 | 0x400 | 0x800 | (UInt64(1) << 53) | uxn
}

// 16 KiB granule uses eleven index bits per level and a 14-bit offset.
public func armWalkIndex(_ va: UInt64, level: UInt8) -> UInt64 {
  if level > 3 { return 2048 }
  return (va >> (14 + (3 - UInt64(level)) * 11)) & 2047
}
