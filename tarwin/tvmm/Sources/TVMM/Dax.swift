// Window offsets address a VM-local PCI shared-memory region. Backing entries
// contain pinned volume-scoped file IDs, never a guest path or host fd.
public struct DaxExtent {
  public let start: UInt64
  public let end: UInt64
  public let file: UInt64
  public let offset: UInt64
  public let writable: Bool

  public init(start: UInt64, end: UInt64, file: UInt64, offset: UInt64, writable: Bool) {
    self.start = start
    self.end = end
    self.file = file
    self.offset = offset
    self.writable = writable
  }
}
public struct DaxWindow {
  public let size: UInt64
  public let align: UInt64
  public let extentLimit: Int
  public let epoch: UInt64
  public internal(set) var live: [DaxExtent] = []

  public init(size: UInt64, align: UInt64, extentLimit: Int, epoch: UInt64) {
    self.size = size
    self.align = align
    self.extentLimit = extentLimit
    self.epoch = epoch
  }

  // file == 0 removes a range. For setup the service first resolves 'file'
  // beneath the active picker grant, including aliases and symlinks. The
  // callback pins new extents, replaces translations, waits for shootdown and
  // releases old pins atomically, or leaves the previous snapshot intact.
  public mutating func replace(
    _ generation: UInt64, _ start: UInt64, _ length: UInt64, _ file: UInt64, _ offset: UInt64,
    _ fileSize: UInt64, _ writable: Bool, _ grantWrite: Bool,
    _ install: ([DaxExtent]) -> Bool
  ) -> Bool {
    if generation != epoch || align == 0 || (align & (align - 1)) != 0
      || start % align != 0 || length == 0 || length % align != 0 || start > size
      || length > size - start
    {
      return false
    }
    if file != 0
      && (offset % align != 0 || offset > fileSize || length > fileSize - offset
        || (writable && !grantWrite))
    {
      return false
    }
    let end = start + length
    var result: [DaxExtent] = []
    for old in live {
      if old.end <= start || old.start >= end {
        result.append(old)
        continue
      }
      if old.start < start {
        result.append(
          DaxExtent(
            start: old.start, end: start, file: old.file, offset: old.offset, writable: old.writable
          ))
      }
      if old.end > end {
        result.append(
          DaxExtent(
            start: end, end: old.end, file: old.file,
            offset: old.offset + (end - old.start), writable: old.writable))
      }
    }
    if file != 0 {
      result.append(
        DaxExtent(start: start, end: end, file: file, offset: offset, writable: writable))
    }
    if result.count > extentLimit || !install(result) { return false }
    live = result
    return true
  }
}
