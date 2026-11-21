import Foundation
import TIRImage

struct InputError: Error, CustomStringConvertible {
  let description: String
  init(_ reason: String) { description = reason }
}

// Narrow stage-0 bridge: accept only the live, read-only AArch64 or x64 ET_REL
// produced by kernel-object.sh. A12, not this importer, lays out the image
// and resolves its relocations. Never ignore an unknown allocated section.
private struct Input {
  var bytes: [UInt8]
  func number(_ at: Int, _ n: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<n { v |= UInt64(bytes[at + i]) << (8 * i) }
    return v
  }
  func extent(_ base: UInt64, _ size: UInt64) throws -> Range<Int> {
    guard base <= bytes.count, size <= UInt64(bytes.count) - base else {
      throw InputError("file extent outside object")
    }
    return Int(base)..<Int(base + size)
  }
  func string(_ offset: UInt64, in table: Range<Int>) throws -> String {
    guard offset < table.count else { throw InputError("bad string offset") }
    let start = table.lowerBound + Int(offset)
    guard let end = bytes[start..<table.upperBound].firstIndex(of: 0),
      let s = String(bytes: bytes[start..<end], encoding: .utf8)
    else { throw InputError("bad string") }
    return s
  }
}

func readKernelObject(_ bytes: [UInt8]) throws -> ObjectFile {
  let f = Input(bytes: bytes)
  guard bytes.count >= 64, bytes.count <= 8 << 20,
    Array(bytes.prefix(7)) == [127, 69, 76, 70, 2, 1, 1],
    f.number(16, 2) == 1, [62, 183].contains(f.number(18, 2)), f.number(20, 4) == 1, f.number(52, 2) == 64,
    f.number(56, 2) == 0, f.number(58, 2) == 64
  else { throw InputError("expected little-endian AArch64 or x64 ELF64 ET_REL") }
  let arm = f.number(18, 2) == 183
  let count = Int(f.number(60, 2))
  let names = Int(f.number(62, 2))
  guard count > 1, names > 0, names < count else { throw InputError("invalid section directory") }
  let table = try f.extent(f.number(40, 8), UInt64(count) * 64)
  guard bytes[table.prefix(64)].allSatisfy({ $0 == 0 }) else {
    throw InputError("extended section numbering is unsupported")
  }
  func field(_ i: Int, _ off: Int, _ n: Int) -> UInt64 {
    f.number(table.lowerBound + i * 64 + off, n)
  }
  func body(_ i: Int) throws -> Range<Int> { try f.extent(field(i, 24, 8), field(i, 32, 8)) }
  guard field(names, 4, 4) == 3 else { throw InputError("missing section names") }
  let strings = try body(names)
  func sectionName(_ i: Int) throws -> String { try f.string(field(i, 0, 4), in: strings) }
  var sections: [ObjectSection] = []
  var mapped = [Int: Int]()
  var symbols: [ObjectSymbol] = []
  var allocated = 0
  for i in 1..<count where field(i, 8, 8) & 2 != 0 {
    let flags = field(i, 8, 8)
    let alignment = field(i, 48, 8)
    let name = try sectionName(i)
    guard field(i, 4, 4) == 1, flags & ~UInt64(2 | 4 | 16 | 32 | 0x20_0000) == 0, alignment > 0,
      alignment <= 16384, alignment.nonzeroBitCount == 1
    else { throw InputError("unsupported allocated section: " + name) }
    let code = flags & 4 != 0
    guard
      code
        ? (name == ".text" || name.hasPrefix(".text."))
        : (name == ".rodata" || name.hasPrefix(".rodata."))
    else { throw InputError("unexpected section permissions: " + name) }
    let index = sections.count
    let b = try body(i)
    allocated += b.count + Int(alignment) - 1
    guard allocated <= 8 << 20 else { throw InputError("kernel sections exceed W0 size bound") }
    mapped[i] = index
    sections.append(
      .init(kind: code ? .text : .readOnlyData, alignment: Int(alignment), bytes: Array(bytes[b])))
    symbols.append(
      .init(name: "section.\(i)", section: index, binding: .local, kind: code ? .function : .data))
  }
  let tables = (1..<count).filter { field($0, 4, 4) == 2 }
  guard tables.count == 1, let syms = tables.first, field(syms, 56, 8) == 24 else {
    throw InputError("expected one symbol table")
  }
  let sym = try body(syms)
  let str = Int(field(syms, 40, 4))
  guard sym.count % 24 == 0, str < count, field(str, 4, 4) == 3 else {
    throw InputError("invalid symbol table")
  }
  let sn = try body(str)
  var entry = false
  for at in stride(from: sym.lowerBound, to: sym.upperBound, by: 24) {
    guard try f.string(f.number(at, 4), in: sn) == "tarwin_start_body" else { continue }
    let section = Int(f.number(at + 6, 2))
    let offset = f.number(at + 8, 8)
    let size = f.number(at + 16, 8)
    guard !entry, bytes[at + 4] == 0x12, let index = mapped[section], sections[index].kind.isCode,
      !arm || offset & 3 == 0, offset < sections[index].size, size > 0,
      size <= UInt64(sections[index].size) - offset
    else { throw InputError("invalid entry function") }
    entry = true
    symbols.append(
      .init(
        name: "tarwin_start_body", section: index, offset: Int(offset), size: Int(size),
        binding: .exported))
  }
  guard entry else { throw InputError("no tarwin_start_body") }
  for i in 1..<count where field(i, 4, 4) == 4 || field(i, 4, 4) == 9 {
    guard let destination = mapped[Int(field(i, 44, 4))], field(i, 4, 4) == 4,
      field(i, 56, 8) == 24,
      field(i, 40, 4) == syms
    else { throw InputError("unsupported relocation section") }
    let rel = try body(i)
    guard rel.count % 24 == 0 else { throw InputError("truncated RELA") }
    for at in stride(from: rel.lowerBound, to: rel.upperBound, by: 24) {
      let off = f.number(at, 8)
      let info = f.number(at + 8, 8)
      let s = info >> 32
      guard !arm || (sections[destination].kind.isCode && off & 3 == 0), off <= sections[destination].size,
        UInt64(sections[destination].size) - off >= 4, s < sym.count / 24
      else { throw InputError("bad relocation extent") }
      let source = sym.lowerBound + Int(s) * 24
      let referenced = Int(f.number(source + 6, 2))
      guard let target = mapped[referenced], let value = Int64(exactly: f.number(source + 8, 8))
      else { throw InputError("unresolved relocation") }
      let (addend, overflow) = value.addingReportingOverflow(
        Int64(bitPattern: f.number(at + 16, 8)))
      guard !overflow else { throw InputError("relocation addend overflow") }
      if !arm {
        // x64 RIP-relative instruction operands use a -4 PC bias. Relative
        // jump-table words use S+A-P (with a cell-relative bias in A).
        let type = UInt32(truncatingIfNeeded: info)
        guard type == 2 || (type == 4 && sections[destination].kind.isCode) else {
          throw InputError("unsupported x64 relocation")
        }
        let bias = sections[destination].kind.isCode ? Int64(4) : -Int64(off)
        let (actual, wraps) = addend.addingReportingOverflow(bias)
        guard !wraps, actual >= 0, actual < sections[target].size else {
          throw InputError("x64 relocation outside target")
        }
        sections[destination].relocations.append(.init(offset: Int(off),
          kind: type == 2 ? .x64PCRelative32 : .x64Branch32, symbol: "section.\(referenced)", addend: addend))
        continue
      }
      guard addend >= 0, addend < sections[target].size else {
        throw InputError("relocation outside target")
      }
      let kind: RelocationKind
      switch UInt32(truncatingIfNeeded: info) {
      case 282, 283: kind = .aarch64Branch26
      case 275: kind = .aarch64Page21
      case 277: kind = .aarch64AddLow12
      case 278: kind = .aarch64LoadStoreLow12(sizeLog2: 0)
      case 284: kind = .aarch64LoadStoreLow12(sizeLog2: 1)
      case 285: kind = .aarch64LoadStoreLow12(sizeLog2: 2)
      case 286: kind = .aarch64LoadStoreLow12(sizeLog2: 3)
      default: throw InputError("unsupported AArch64 relocation \(UInt32(truncatingIfNeeded:info))")
      }
      sections[destination].relocations.append(
        .init(offset: Int(off), kind: kind, symbol: "section.\(referenced)", addend: addend))
    }
  }
  return .init(name: "body", architecture: arm ? .aarch64 : .x64, sections: sections, symbols: symbols)
}
