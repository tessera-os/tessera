// Kernel-owned R/W bit masks are prepared from the enumerated function's
// register layout. Unclassified registers (in particular all capabilities)
// are read-only. Only device-specific R/W registers may be opted in; a
// change to the standard header is always mediated by a slot operation.
public func pciConfigWriteAllowed(
  _ offset: UInt32, _ width: UInt32, _ requested: UInt32, _ writable: UInt32, _ oldValue: UInt32,
  _ plainReadWrite: Bool
) -> Bool {
  if width != 1 && width != 2 && width != 4 { return false }
  if offset < 0x40 || offset >= 0x100 || offset % width != 0 { return false }
  // Conventional capabilities also live below 0x100. A raw config write
  // is never permitted there without a kernel-classified ordinary register.
  if !plainReadWrite || writable == 0 { return false }
  var mask: UInt32 = 0xffff_ffff
  if width == 1 { mask = 0xff }
  if width == 2 { mask = 0xffff }
  if requested > mask || writable > mask { return false }
  return ((oldValue ^ requested) & (mask ^ writable)) == 0
}

public func inDriverApiWindow(
  _ trainYear: UInt32, _ trainMonth: UInt32, _ driverYear: UInt32, _ driverMonth: UInt32
) -> Bool {
  if trainYear > 99 || driverYear > 99 || trainMonth < 1 || trainMonth > 12 || driverMonth < 1
    || driverMonth > 12
  {
    return false
  }
  let train = trainYear * 12 + trainMonth
  let target = driverYear * 12 + driverMonth
  return target >= 26 * 12 + 11 && train >= target && train - target < 12
}
