// Standalone image has no libc. Used for compiler-lowered zeroing of the
// private arena/bank. Keep the byte loop from becoming a call to itself.
@_optimize(none) @_cdecl("memset")
public func probeFill(_ dst: UnsafeMutableRawPointer, _ value: Int32, _ count: Int)
  -> UnsafeMutableRawPointer
{
  for i in 0..<count {
    dst.storeBytes(of: UInt8(truncatingIfNeeded: value), toByteOffset: i, as: UInt8.self)
  }
  return dst
}
