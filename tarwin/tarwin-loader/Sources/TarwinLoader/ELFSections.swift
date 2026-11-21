enum LoaderSection {
  case absent, invalid
  case found(Range<Int>)
}

extension ELFReader {
  private func extent(at: Int) -> Range<Int>? {
    let start = u64(at)
    let size = u64(at + 8)
    guard imageContains(UInt64(bytes.count), start, size) else { return nil }
    return Int(start)..<Int(start + size)
  }

  /// Only ordinary ELF64 section numbering is supported. On this path do
  /// not allocate or scan string lengths proportional to attacker input.
  func findLoaderRecords(programs: Range<Int>) -> LoaderSection {
    let offset = u64(40)
    let count = Int(u16(60))
    let strings = Int(u16(62))
    if offset == 0 { return count == 0 && strings == 0 ? .absent : .invalid }
    guard (1..<0xff00).contains(count), u16(58) == 64, offset >= 64, offset & 7 == 0,
      imageContains(UInt64(bytes.count), offset, UInt64(count) * 64),
      strings > 0, strings < count
    else { return .invalid }
    let table = Int(offset)..<(Int(offset) + count * 64)
    guard !table.overlaps(programs), u32(table.lowerBound + 4) == 0 else { return .invalid }
    let shstr = table.lowerBound + strings * 64
    guard u32(shstr + 4) == 3, u64(shstr + 8) & 0x800 == 0, let names = extent(at: shstr + 24),
      !names.isEmpty, bytes[names.lowerBound] == 0, bytes[names.upperBound - 1] == 0
    else { return .invalid }
    var result: Range<Int>?
    for at in stride(from: table.lowerBound + 64, to: table.upperBound, by: 64) {
      let name = Int(u32(at))
      guard name < names.count else { return .invalid }
      guard names.count - name >= 9 else { continue }
      let p = names.lowerBound + name
      // ".tirload" is exactly eight ASCII bytes, followed by NUL.
      guard u64(p) == 0x6461_6f6c_7269_742e && bytes[p + 8] == 0 else { continue }
      let flags = u64(at + 8)
      guard result == nil, u32(at + 4) == 1, flags & ~2 == 0, let data = extent(at: at + 24),
        !data.isEmpty, data.lowerBound >= 64, !data.overlaps(table), !data.overlaps(names),
        !data.overlaps(programs)
      else { return .invalid }
      result = data
    }
    guard let result else { return .absent }
    for at in stride(from: programs.lowerBound, to: programs.upperBound, by: 56) {
      let kind = u32(at)
      if kind == 4 || (kind == 1 && u32(at + 4) & 3 != 0) {
        let file = u64(at + 8)
        let size = u64(at + 32)
        // PT_NOTE and PT_LOAD extents have already passed imageContains.
        if size != 0, result.overlaps(Int(file)..<Int(file + size)) { return .invalid }
      }
    }
    return .found(result)
  }
}
