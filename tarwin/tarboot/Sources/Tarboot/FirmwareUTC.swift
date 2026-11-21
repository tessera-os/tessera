// EFI_TIME from a clock independently configured as UTC by the QEMU harness.
// Not a secure wall clock for physical installations or other emulators.
public func emulatorUTC(_ b: UnsafeRawBufferPointer) -> UInt64? {
  guard b.count == 16 else { return nil }
  let year = Int(b[0]) | Int(b[1]) << 8
  let month = Int(b[2])
  let day = Int(b[3])
  let ns = b.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
  let zone = b.loadUnaligned(fromByteOffset: 12, as: UInt16.self).littleEndian
  guard (1970...9999).contains(year), (1...12).contains(month), day > 0,
    b[4] < 24, b[5] < 60, b[6] < 60, ns < 1_000_000_000,
    zone == 0 || zone == 2047, b[14] == 0
  else { return nil }
  func leaps(_ y: Int) -> Int { y / 4 - y / 100 + y / 400 }
  let leap = leaps(year) != leaps(year - 1)
  var days = (year - 1970) * 365 + leaps(year - 1) - leaps(1969)
  for m in 1...month {
    let n: Int
    switch m {
    case 2: n = leap ? 29 : 28
    case 4, 6, 9, 11: n = 30
    default: n = 31
    }
    if m < month { days += n } else if day > n { return nil }
  }
  return UInt64(((days + day - 1) * 24 + Int(b[4])) * 3600 + Int(b[5]) * 60 + Int(b[6]))
}
