// Bitmap is allocated/zeroed by the VM owner; callbacks address its private
// words under the VM dirty lock. DMA writes require IOMMU-side dirty tracking.
// A collector re-arms write traps/clears hardware dirty state AND waits for TLB
// acknowledgement before clearing a word; writers may not race this transition.
public struct DirtyPages {
  public let first: UInt64
  public let pages: UInt64

  public init(first: UInt64, pages: UInt64) {
    self.first = first
    self.pages = pages
  }

  public func mark(
    _ page: UInt64, _ count: UInt64,
    _ load: (UInt64) -> UInt64, _ store: (UInt64, UInt64) -> Void
  ) -> Bool {
    if pages == 0 || pages - 1 > 0xffff_ffff_ffff_ffff - first || count == 0
      || page < first || page - first >= pages || count > pages - (page - first)
    {
      return false
    }
    let start = page - first
    let end = start + count - 1
    var index = start / 64
    while index <= end / 64 {
      let mask = dirtyWord(index * 64, start, count)
      store(index, load(index) | mask)
      index += 1
    }
    return true
  }
  public func collectWord(
    _ index: UInt64, _ load: (UInt64) -> UInt64,
    _ rearmAndWait: (UInt64, UInt64) -> Bool, _ store: (UInt64, UInt64) -> Void,
    _ emit: (UInt64, UInt64) -> Bool
  ) -> Bool {
    if pages == 0 || pages - 1 > 0xffff_ffff_ffff_ffff - first || index > (pages - 1) / 64 {
      return false
    }
    let start = index * 64
    let count = pages - start < 64 ? pages - start : UInt64(64)
    let mask = count == 64 ? UInt64(0xffff_ffff_ffff_ffff) : (UInt64(1) << count) - 1
    let bits = load(index) & mask
    if !rearmAndWait(first + start, count) || !emit(index, bits) { return false }
    store(index, 0)
    return true
  }
}
