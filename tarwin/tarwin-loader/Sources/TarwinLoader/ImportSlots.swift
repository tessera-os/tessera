/// The TLD1 structural reader has already checked all cursor extents and
/// tags. Here RVAs are checked against the *same* complete file. This does
/// not bind a symbol, authenticate the file or install a function pointer.
extension ELFReader {
  func validImportSlots(
    _ image: InspectedImage, directory: LoaderDirectory, section: Range<Int>, machine: UInt16
  ) -> Bool {
    let imports = directory[.imports]
    let runtime = directory[.runtime]
    let dispatch = directory[.dispatch]
    let total = UInt64(imports.count) + UInt64(runtime.count) + UInt64(dispatch.count)
    let area: ELFSection
    switch findSection(".tirimport", programs: image.programHeaders, use: .relro) {
    case .invalid: return false
    case .absent: return total == 0
    case .found(let located): area = located
    }
    let start = area.file.lowerBound
    guard !area.file.overlaps(section), area.address & 7 == 0,
      UInt64(area.file.count) == 16 + total * 8
    else { return false }
    let functions = UInt64(u32(start))
    let data = UInt64(u32(start + 4))
    guard functions + data == UInt64(imports.count), u32(start + 8) == runtime.count,
      u32(start + 12) == dispatch.count
    else { return false }
    for p in stride(from: start + 16, to: area.file.upperBound, by: 8) where u64(p) != 0 {
      return false
    }
    func cursor(_ t: LoaderTable) -> WireCursor {
      WireCursor(
        reader: self, pos: section.lowerBound + t.bytes.lowerBound,
        end: section.lowerBound + t.bytes.upperBound)
    }
    let slots = area.address + 16
    let run = slots + 8 * functions
    let choices = run + 8 * UInt64(runtime.count)
    let values = choices + 8 * UInt64(dispatch.count)
    var f = slots
    var d = values
    var c = cursor(imports)
    while c.pos < c.end {
      guard let h = c.take(30) else { return false }
      if bytes[h + 8] == 0 {
        guard f < run, u64(h) == f else { return false }
        f += 8
      } else {
        guard f == run, d < values + data * 8, u64(h) == d else { return false }
        d += 8
      }
      guard c.text() != nil, c.text() != nil else { return false }
    }
    c = cursor(runtime)
    var slot = run
    while c.pos < c.end {
      guard let h = c.take(10), u64(h) == slot else { return false }
      slot += 8
    }
    c = cursor(dispatch)
    var hint: Int?
    while c.pos < c.end {
      guard let h = c.take(14), u64(h) == slot else { return false }
      slot += 8
      for _ in 0..<u16(h + 12) {
        guard let p = c.take(8),
          validLocalEntry(
            u64(p), tag: u32(h + 8), machine: machine, programs: image.programHeaders, hint: &hint),
          c.features()
        else { return false }
      }
    }
    let reserved = area.address..<(area.address + UInt64(area.file.count))
    // No other table may alter the header or a slot (including via RELR).
    var relr = RelativeCursor(anchorSeen: false, nextBase: 0, bits: 0, at: 0, imageSize: .max)
    c = cursor(directory[.relative])
    while let h = c.take(8) {
      guard relr.accept(u64(h)) else { return false }
      while relr.bits != 0 { if reserved.contains(relr.take()) { return false } }
    }
    for k in 0..<3 {
      c = cursor(directory[k == 0 ? .authenticated : (k == 1 ? .tls : .features)])
      while c.pos < c.end {
        guard let h = c.take(8), !reserved.contains(u64(h)) else { return false }
        if k == 2 {
          guard c.text() != nil else { return false }
        } else {
          guard c.take(k == 0 ? 4 : 8) != nil else { return false }
        }
      }
    }
    return true
  }

  func validLocalEntry(
    _ entry: UInt64, tag: UInt32, machine: UInt16, programs: Range<Int>, hint: inout Int?
  ) -> Bool {
    let before: UInt64 = machine == ElfMachine.x64 ? 5 : 4
    guard entry & 15 == 0, entry >= before else { return false }
    func fileAddress(_ h: Int) -> Int? {
      let va = u64(h + 16)
      let start = entry - before
      guard u32(h) == 1, u32(h + 4) == 5, start >= va,
        imageContains(u64(h + 32), start - va, before + 4)
      else { return nil }
      return Int(u64(h + 8) + (entry - va))
    }
    var at = hint.flatMap { fileAddress($0) }
    if at == nil {
      for h in stride(from: programs.lowerBound, to: programs.upperBound, by: 56) {
        if let p = fileAddress(h) {
          at = p
          hint = h
          break
        }
      }
    }
    guard let at, u32(at - 4) == tag else { return false }
    switch machine {
    case ElfMachine.aarch64: return u32(at) == 0xd503_245f
    case ElfMachine.x64: return bytes[at - 5] == 0xb8 && u32(at) == 0xfa1e_0ff3
    case ElfMachine.rv64: return u32(at) == (tag << 12 | 0x17)
    default: return false
    }
  }
}
