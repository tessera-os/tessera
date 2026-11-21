enum LoaderSection {
  case absent, invalid
  case found(Range<Int>)
}

enum SectionUse { case metadata, unloaded, relro }

struct ELFSection {
  let file: Range<Int>
  let address: UInt64
}

enum SectionLookup {
  case absent, invalid
  case found(ELFSection)
}

extension ELFReader {
  func extent(at: Int) -> Range<Int>? {
    let start = u64(at)
    let size = u64(at + 8)
    guard imageContains(UInt64(bytes.count), start, size) else { return nil }
    return Int(start)..<Int(start + size)
  }

  /// Only ordinary ELF64 section numbering is supported. On this path do
  /// not allocate or scan string lengths proportional to attacker input.
  func findMetadataSection(_ sectionName: StaticString, programs: Range<Int>, unloaded: Bool)
    -> LoaderSection
  {
    switch findSection(sectionName, programs: programs, use: unloaded ? .unloaded : .metadata) {
    case .absent: return .absent
    case .invalid: return .invalid
    case .found(let section): return .found(section.file)
    }
  }

  func findSection(_ sectionName: StaticString, programs: Range<Int>, use: SectionUse)
    -> SectionLookup
  {
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
    var result: ELFSection?
    for at in stride(from: table.lowerBound + 64, to: table.upperBound, by: 64) {
      let name = Int(u32(at))
      guard name < names.count else { return .invalid }
      let n = sectionName.utf8CodeUnitCount
      guard names.count - name > n else { continue }
      let p = names.lowerBound + name
      guard bytes[p + n] == 0, nameEquals(p..<(p + n), sectionName) else { continue }
      let flags = u64(at + 8)
      guard result == nil, u32(at + 4) == 1,
        use == .relro
          ? (flags == 3 || flags == 2) : (flags == 0 || (use == .metadata && flags == 2)),
        let data = extent(at: at + 24),
        !data.isEmpty, data.lowerBound >= 64, !data.overlaps(table), !data.overlaps(names),
        !data.overlaps(programs)
      else { return .invalid }
      result = ELFSection(file: data, address: u64(at + 16))
    }
    guard let result else { return .absent }
    var loaded = false
    var sealed = false
    for at in stride(from: programs.lowerBound, to: programs.upperBound, by: 56) {
      let kind = u32(at)
      if use == .relro && (kind == 1 || kind == 0x6474_e552) {
        let file = u64(at + 8)
        let v = u64(at + 16)
        let n = UInt64(result.file.count)
        guard imageContains(UInt64(bytes.count), file, u64(at + 32)), u64(at + 32) <= u64(at + 40),
          imageContains(UInt64.max, v, u64(at + 40))
        else { return .invalid }
        if UInt64(result.file.lowerBound) >= file, result.address >= v,
          result.address - v == UInt64(result.file.lowerBound) - file,
          imageContains(u64(at + 32), result.address - v, n),
          imageContains(u64(at + 40), result.address - v, n)
        {
          if kind == 1 && u32(at + 4) == 6 { loaded = true }
          if kind != 1 { sealed = true }
        }
      }
      if kind == 4 || (kind == 1 && use != .relro && (use == .unloaded || u32(at + 4) & 3 != 0)) {
        let file = u64(at + 8)
        let size = u64(at + 32)
        // PT_NOTE and PT_LOAD extents have already passed imageContains.
        if size != 0, result.file.overlaps(Int(file)..<Int(file + size)) { return .invalid }
      }
    }
    return use == .relro && !(loaded && sealed) ? .invalid : .found(result)
  }
}
