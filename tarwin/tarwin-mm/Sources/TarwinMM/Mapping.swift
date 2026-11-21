import KCore

// A.2: 0 invalid, 1 image, 2 ordinary mapping, 3 GPU, 4 shared
// kernel-supplied pages. No interval may cross from one class into another.
public func userRegion(_ base: UInt64, length: UInt64, pageSize: UInt64, userBits: UInt8) -> UInt8 {
  if (pageSize != 4096 && pageSize != 16384) || !alignedTo(base, alignment: pageSize)
    || !alignedTo(length, alignment: pageSize)
  {
    return 0
  }
  if userBits != 47 && userBits != 56 { return 0 }
  let high = UInt64(1) << UInt64(userBits)
  if withinRange(base, length: length, lower: UInt64(1) << 32, upper: UInt64(1) << 43) { return 1 }
  if withinRange(base, length: length, lower: UInt64(1) << 43, upper: UInt64(1) << 46) { return 2 }
  if withinRange(
    base, length: length, lower: UInt64(1) << 46, upper: (UInt64(1) << 47) - (UInt64(1) << 36))
  {
    return 3
  }
  if withinRange(base, length: length, lower: high - (UInt64(1) << 36), upper: high) { return 4 }
  return 0
}

// TIR code pages come only from verified code objects; write permission
// must not survive sealing. Rights are checked before any PTE is written.
public func permitsMapping(
  _ protection: UInt8, readable: Bool, writable: Bool, executable: Bool, code: Bool, sealed: Bool
) -> Bool {
  if !readable { return false }
  if protection == 1 { return true }
  if protection == 3 { return writable && !sealed && !code }
  return protection == 5 && executable && code && sealed
}

public func fitsReservation(
  _ base: UInt64, size: UInt64, reservedBase: UInt64, reservedSize: UInt64
) -> Bool {
  if !validExtent(reservedBase, length: reservedSize) { return false }
  return withinRange(base, length: size, lower: reservedBase, upper: reservedBase + reservedSize)
}
