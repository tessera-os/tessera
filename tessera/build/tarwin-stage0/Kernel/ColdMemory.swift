// The compiler supplies valid normal-RAM ranges; devices use volatile accessors.
// With the MMU off, even ordinary RAM cannot be accessed with unaligned words.
#if os(none)
@_cdecl("memcpy")
#endif
public func coldCopy(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> UnsafeMutableRawPointer {
  var n = 0
  if (UInt(bitPattern: dst) | UInt(bitPattern: src)) & 7 == 0 {
    while count - n >= 8 {
      dst.storeBytes(of: src.load(fromByteOffset: n, as: UInt64.self), toByteOffset: n, as: UInt64.self)
      n += 8
    }
  }
  while n < count {
    dst.storeBytes(of: src.load(fromByteOffset: n, as: UInt8.self), toByteOffset: n, as: UInt8.self)
    n += 1
  }
  return dst
}

#if os(none)
@_cdecl("memmove")
#endif
public func coldMove(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> UnsafeMutableRawPointer {
  let d = UInt(bitPattern: dst), s = UInt(bitPattern: src)
  if d == s { return dst }
  if d < s || d - s >= UInt(count) { return coldCopy(dst, src, count) }
  var n = count
  while n > 0 {
    n -= 1
    dst.storeBytes(of: src.load(fromByteOffset: n, as: UInt8.self), toByteOffset: n, as: UInt8.self)
  }
  return dst
}

// Do not let loop-idiom recognition replace the fill with a call to itself.
@inline(never)
private func putWord(_ p: UnsafeMutableRawPointer, _ n: Int, _ x: UInt64) {
  p.storeBytes(of: x, toByteOffset: n, as: UInt64.self)
}
@inline(never)
private func putByte(_ p: UnsafeMutableRawPointer, _ n: Int, _ x: UInt8) {
  p.storeBytes(of: x, toByteOffset: n, as: UInt8.self)
}
#if os(none)
@_cdecl("memset")
#endif
public func coldSet(_ dst: UnsafeMutableRawPointer, _ value: Int32, _ count: Int) -> UnsafeMutableRawPointer {
  let byte = UInt8(truncatingIfNeeded: value)
  var n = 0
  if UInt(bitPattern: dst) & 7 == 0 {
    let fill = UInt64(byte) * 0x0101_0101_0101_0101
    while count - n >= 8 {
      putWord(dst, n, fill)
      n += 8
    }
  }
  while n < count {
    putByte(dst, n, byte)
    n += 1
  }
  return dst
}
