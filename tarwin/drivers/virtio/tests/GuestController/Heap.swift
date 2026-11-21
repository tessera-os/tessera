// Bump allocator over loader pages for VirtioGuest's arrays; free (a no-op)
// is in Access.swift because Swift reserves that symbol name.
nonisolated(unsafe) private var next: UInt = 0
nonisolated(unsafe) private var end: UInt = 0

func heapStart(_ base: UInt64, _ length: UInt64) {
  next = UInt(base)
  end = UInt(base + length)
}

@_cdecl("posix_memalign")
public func posixMemalign(
  _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ alignment: Int, _ size: Int
) -> Int32 {
  let a = UInt(max(alignment, 16))
  let start = (next + a - 1) & ~(a - 1)
  guard next != 0, size >= 0, start <= end, UInt(size) <= end - start else { return 12 }
  next = start + UInt(size)
  out.pointee = UnsafeMutableRawPointer(bitPattern: start)
  return 0
}
