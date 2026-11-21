import KCore

// A pinned frame view consists of one base page followed by the packed
// allocation tags (one four-bit tag per 16 bytes) on a tagged mapping.
public func frameBytes(_ pageSize: UInt64, tagged: Bool) -> UInt64 {
  if pageSize != 4096 && pageSize != 16384 { return 0 }
  if tagged { return pageSize + pageSize / 32 }
  return pageSize
}

public func demandZero<D: ByteBuffer>(_ frame: inout D, pageSize: UInt64, tagged: Bool) -> Bool {
  let n = frameBytes(pageSize, tagged: tagged)
  if n == 0 || n != frame.byteCount() { return false }
  var i: UInt64 = 0
  while i < n {
    frame.putByte(i, value: 0)
    i += 1
  }
  return true
}

// Caller holds the source read-only and the destination exclusively until
// successful publication under its object lock. No aliasing or PTE writes.
public func privateCopy<S: ByteSource, D: ByteBuffer>(
  _ source: S, frame: inout D, pageSize: UInt64, tagged: Bool
) -> Bool {
  let n = frameBytes(pageSize, tagged: tagged)
  if n == 0 || n != source.byteCount() || n != frame.byteCount() { return false }
  var i: UInt64 = 0
  while i < n {
    frame.putByte(i, value: source.byteAt(i))
    i += 1
  }
  return true
}

// A backing object is bound to one immutable snapshot/version for its
// lifetime. pinFilePage returns a lease on the file-cache frame itself.
// The provider zeroes the final-page tail and never reuses a leased frame.
// A writer must obtain a writable lease before installing a writable PTE;
// release follows unmapping and the last TLB invalidation, never precedes it.
public struct FilePageLease {
  public internal(set) var token: UInt64
  public internal(set) var physical: UInt64

  public init(token: UInt64, physical: UInt64) {
    self.token = token
    self.physical = physical
  }
}

public protocol FilePager {
  mutating func pinFilePage(
    _ object: UInt64, offset: UInt64, validBytes: UInt64, pageSize: UInt64, write: Bool
  ) -> FilePageLease
  mutating func unpinFilePage(_ token: UInt64, dirty: Bool)
}

public func faultFilePage<P: FilePager>(
  _ pager: inout P, object: UInt64, size: UInt64, offset: UInt64, pageSize: UInt64, write: Bool
) -> FilePageLease {
  let none = FilePageLease(token: 0, physical: 0)
  if object == 0 || frameBytes(pageSize, tagged: false) == 0
    || !alignedTo(offset, alignment: pageSize) || offset >= size
  {
    return none
  }
  let left = size - offset
  let count = left < pageSize ? left : pageSize
  let page = pager.pinFilePage(
    object, offset: offset, validBytes: count, pageSize: pageSize, write: write)
  if page.token == 0 { return none }
  if !alignedTo(page.physical, alignment: pageSize) || !validExtent(page.physical, length: pageSize)
  {
    pager.unpinFilePage(page.token, dirty: false)
    return none
  }
  return page
}
