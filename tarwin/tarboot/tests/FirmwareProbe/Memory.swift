// LLVM can lower aggregate copies to this freestanding ABI. The compiler
// guarantees disjoint, valid ranges of 'count' bytes; never use libc here.
@_cdecl("memcpy")
@_optimize(none)
public func probeCopy(
  _ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: UInt
) -> UnsafeMutableRawPointer {
  var n: UInt = 0
  while n < count {
    destination.storeBytes(
      of: source.load(fromByteOffset: Int(n), as: UInt8.self),
      toByteOffset: Int(n), as: UInt8.self)
    n += 1
  }
  return destination
}

// Raw buffer copies additionally permit overlap.
@_cdecl("memmove")
@_optimize(none)
public func probeMove(
  _ destination: UnsafeMutableRawPointer, _ source: UnsafeRawPointer, _ count: UInt
) -> UnsafeMutableRawPointer {
  let backward = UInt(bitPattern: destination) > UInt(bitPattern: source)
  var n: UInt = 0
  while n < count {
    let i = Int(backward ? count - 1 - n : n)
    destination.storeBytes(
      of: source.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
    n += 1
  }
  return destination
}

// As above, the destination is a writable compiler-provided extent.
@_cdecl("memset")
@_optimize(none)
public func probeSet(_ destination: UnsafeMutableRawPointer, _ value: Int32, _ count: UInt)
  -> UnsafeMutableRawPointer
{
  var n: UInt = 0
  while n < count {
    destination.storeBytes(
      of: UInt8(truncatingIfNeeded: value), toByteOffset: Int(n), as: UInt8.self)
    n += 1
  }
  return destination
}
