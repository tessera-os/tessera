// The arch entry provider supplies the address of the instruction, not its
// return PC. VM supplies the verified executable mapping (not the image span).
public func syscallOriginAllowed(
  _ instruction: UInt64, _ width: UInt64, _ start: UInt64, _ end: UInt64
) -> Bool {
  if width != 2 && width != 4 { return false }
  if start >= end || instruction < start || instruction >= end { return false }
  return width <= end - instruction
}

// Number of user-copy bytes required by Appendix A.3. registerCount is
// trusted arch metadata, slots is the trusted signature, never user input.
public func syscallTailBytes(_ slots: UInt32, _ registerCount: UInt32) -> UInt64 {
  if slots <= registerCount { return 0 }
  return (UInt64(slots) - UInt64(registerCount) + 1) * 8
}

public func syscallTailInRange(_ address: UInt64, _ bytes: UInt64, _ first: UInt64, _ end: UInt64)
  -> Bool
{
  if bytes == 0 || (bytes & 7) != 0 { return false }
  if (address & 7) != 0 || address < first || address >= end { return false }
  return bytes <= end - address
}

public func syscallStatus(_ code: UInt32, _ subsystem: UInt16) -> UInt64 {
  if code == 0 { return 0 }
  return UInt64(code) | (UInt64(subsystem) << 32)
}
