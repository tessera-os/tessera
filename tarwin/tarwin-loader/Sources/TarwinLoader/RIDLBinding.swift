/// Structural binding only. These RVAs are not pointers: authenticate both
/// immutable images before placement; sign the resolved function pointer
/// with the process keys on AArch64 and seal RELRO before starting the thread.
public struct NativeFunctionBinding {
  public let slotRVA, entryRVA: UInt64
  public let typeTag: UInt32
}

extension ELFReader {
  // The caller has validated this file's program and section tables.
  func exportedFunction(
    _ symbol: UnsafeRawBufferPointer, tag: UInt32, machine: UInt16,
    programs: Range<Int>
  ) -> UInt64? {
    let table = Int(u64(40))
    let count = Int(u16(60))
    var syms: Int?
    for i in 1..<count {
      let s = table + i * 64
      if u32(s + 4) == 11 {
        guard syms == nil else { return nil }
        syms = s
      }
    }
    guard let syms, !symbol.isEmpty, u64(syms + 56) == 24, u64(syms + 8) & ~2 == 0,
      let symbols = extent(at: syms + 24), symbols.count >= 48, symbols.count % 24 == 0
    else { return nil }
    let link = Int(u32(syms + 40))
    guard link > 0, link < count else { return nil }
    let str = table + link * 64
    guard u32(str + 4) == 3, u64(str + 8) & ~2 == 0, let strings = extent(at: str + 24),
      !strings.isEmpty, !symbols.overlaps(strings), bytes[strings.lowerBound] == 0,
      bytes[strings.upperBound - 1] == 0
    else { return nil }
    let sections = table..<(table + count * 64)
    guard strings.lowerBound >= 64, symbols.lowerBound >= 64,
      !strings.overlaps(sections), !symbols.overlaps(sections),
      !strings.overlaps(programs), !symbols.overlaps(programs)
    else { return nil }
    for p in stride(from: programs.lowerBound, to: programs.upperBound, by: 56) {
      let kind = u32(p)
      if kind == 4 || (kind == 1 && u32(p + 4) != 4) {
        guard let file = extent(atProgramHeader: p), !strings.overlaps(file),
          !symbols.overlaps(file)
        else { return nil }
      }
    }
    for i in 0..<24 where bytes[symbols.lowerBound + i] != 0 { return nil }
    var found: UInt64?
    for s in stride(from: symbols.lowerBound + 24, to: symbols.upperBound, by: 24) {
      let name = Int(u32(s))
      guard name < strings.count else { return nil }
      let at = strings.lowerBound + name
      guard symbol.count < strings.upperBound - at, bytes[at + symbol.count] == 0,
        bytesMatch(.init(rebasing: bytes[at..<at + symbol.count]), symbol)
      else { continue }
      let ix = Int(u16(s + 6))
      let entry = u64(s + 8)
      let size = max(4, u64(s + 16))
      guard found == nil, bytes[s + 4] == 0x12, bytes[s + 5] == 0, ix > 0, ix < count else {
        return nil
      }
      let text = table + ix * 64
      let address = u64(text + 16)
      guard u32(text + 4) == 1, u64(text + 8) == 6, entry >= address,
        let file = extent(at: text + 24), imageContains(UInt64(file.count), entry - address, size)
      else { return nil }
      var hint: Int?
      guard validLocalEntry(entry, tag: tag, machine: machine, programs: programs, hint: &hint),
        let h = hint, address >= u64(h + 16),
        imageContains(u64(h + 32), address - u64(h + 16), UInt64(file.count)),
        UInt64(file.lowerBound) == u64(h + 8) + (address - u64(h + 16))
      else { return nil }
      found = entry
    }
    return found
  }

  private func extent(atProgramHeader p: Int) -> Range<Int>? {
    let start = u64(p + 8)
    let size = u64(p + 32)
    guard imageContains(UInt64(bytes.count), start, size) else { return nil }
    return Int(start)..<Int(start + size)
  }
}

/// The restricted boot pair has exactly one eager RIDL function import.
/// Module, UUID, symbol and tag come from the caller's validated TLD1 row,
/// never from a path, a guessed RVA or the platform's symbol resolver.
public func inspectEarlyRIDLBinding(
  executable: UnsafeRawBufferPointer, framework: UnsafeRawBufferPointer,
  machine: UInt16, addressLimit: UInt64, scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> NativeFunctionBinding? {
  guard
    let (caller, dir, section) = parsedSigningCandidate(
      executable, machine: machine,
      addressLimit: addressLimit, finalized: false, requiresEntry: true, scratch: scratch),
    let ep = caller.notes.profile, executable[ep.lowerBound] == 1,
    executable[ep.lowerBound + 1] == 0,
    dir[.imports].count == 1,
    let lib = inspectSigningCandidate(
      framework, machine: machine, addressLimit: addressLimit,
      finalized: false, requiresEntry: false, scratch: scratch), lib.entry == 0,
    let fp = lib.notes.profile, framework[fp.lowerBound] == 1, framework[fp.lowerBound + 1] == 1
  else { return nil }
  let imp = dir[.imports].bytes
  let a = ELFReader(bytes: executable)
  let b = ELFReader(bytes: framework)
  var c = WireCursor(
    reader: a, pos: section.lowerBound + imp.lowerBound, end: section.lowerBound + imp.upperBound)
  guard let h = c.take(30), a.u16(h + 8) == 0, let module = c.text(), let name = c.text(),
    c.pos == c.end, a.nameEquals(module, "LibTessera"),
    case .found(let metadata) = b.findMetadataSection(
      ".ridlmeta", programs: lib.programHeaders, unloaded: true)
  else { return nil }
  let identity = RIDLIdentity(
    name: .init(rebasing: executable[module]), uuid: .init(rebasing: executable[h + 10..<h + 26]))
  let tag = a.u32(h + 26)
  guard RIDLMetadata(bytes: .init(rebasing: framework[metadata])).supports(identity),
    let entry = b.exportedFunction(
      .init(rebasing: executable[name]), tag: tag, machine: machine, programs: lib.programHeaders)
  else { return nil }
  return NativeFunctionBinding(slotRVA: a.u64(h), entryRVA: entry, typeTag: tag)
}
