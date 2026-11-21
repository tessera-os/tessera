// Half-open ranges. Use subtraction so wraparound is never permission.
public func withinRange(_ base: UInt64, length: UInt64, lower: UInt64, upper: UInt64) -> Bool {
  return length != 0 && base >= lower && base < upper && length <= upper - base
}

public func validExtent(_ base: UInt64, length: UInt64) -> Bool {
  return length != 0 && length <= UInt64(0xffff_ffff_ffff_ffff) - base
}

public func isPowerOfTwo(_ value: UInt64) -> Bool {
  return value != 0 && (value & (value - 1)) == 0
}

public func alignedTo(_ value: UInt64, alignment: UInt64) -> Bool {
  return isPowerOfTwo(alignment) && (value & (alignment - 1)) == 0
}
