/// Structural view of a TLD1 section. Offsets are relative to the original
/// section. Semantic binding and permissions must be checked before relocation.
public struct LoaderTable {
  public let bytes: Range<Int>
  public let count: UInt32
}

public enum LoaderTableKind: Int {
  case relative, authenticated, imports, runtime, dispatch, tls, gpu, features, dispatchFields
}

public struct LoaderDirectory {
  private let tables:
    (
      LoaderTable, LoaderTable, LoaderTable, LoaderTable,
      LoaderTable, LoaderTable, LoaderTable, LoaderTable
    )
  private let fields: LoaderTable

  fileprivate init(_ r: ELFReader) {
    fields = r.u16(6) == 9 ? r.table(8) : LoaderTable(bytes: r.bytes.count..<r.bytes.count, count: 0)
    tables = (
      r.table(0), r.table(1), r.table(2), r.table(3),
      r.table(4), r.table(5), r.table(6), r.table(7)
    )
  }

  public subscript(_ kind: LoaderTableKind) -> LoaderTable {
    switch kind {
    case .relative: return tables.0
    case .authenticated: return tables.1
    case .imports: return tables.2
    case .runtime: return tables.3
    case .dispatch: return tables.4
    case .tls: return tables.5
    case .gpu: return tables.6
    case .features: return tables.7
    case .dispatchFields: return fields
    }
  }

  var hasDispatch: Bool { self[.dispatch].count != 0 || self[.dispatchFields].count != 0 }
}

extension ELFReader {
  fileprivate func table(_ index: Int) -> LoaderTable {
    let at = 16 + index * 16
    let start = Int(u32(at))
    return LoaderTable(bytes: start..<(start + Int(u32(at + 4))), count: u32(at + 8))
  }

  // Unicode scalar validation without constructing a hosted String.
  func wireText(_ span: Range<Int>) -> Bool {
    var i = span.lowerBound
    while i < span.upperBound {
      let first = bytes[i]
      i += 1
      if first < 128 {
        if first == 0 { return false }
        continue
      }
      guard first >= 0xc2 && first <= 0xf4 else { return false }
      let n = first < 0xe0 ? 1 : (first < 0xf0 ? 2 : 3)
      guard n <= span.upperBound - i else { return false }
      let second = bytes[i]
      if (first == 0xe0 && second < 0xa0) || (first == 0xed && second >= 0xa0)
        || (first == 0xf0 && second < 0x90) || (first == 0xf4 && second >= 0x90)
      {
        return false
      }
      for j in i..<(i + n) where bytes[j] & 0xc0 != 0x80 { return false }
      i += n
    }
    return !span.isEmpty
  }

  func precedes(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
    for j in 0..<min(lhs.count, rhs.count) {
      let a = bytes[lhs.lowerBound + j]
      let b = bytes[rhs.lowerBound + j]
      if a != b { return a < b }
    }
    return lhs.count < rhs.count
  }
}

struct WireCursor {
  let reader: ELFReader
  var pos: Int
  let end: Int

  mutating func take(_ count: Int) -> Int? {
    guard count <= end - pos else { return nil }
    let at = pos
    pos += count
    return at
  }

  mutating func text() -> Range<Int>? {
    guard let h = take(2) else { return nil }
    let n = Int(reader.u16(h))
    guard let p = take(n) else { return nil }
    let span = p..<(p + n)
    return reader.wireText(span) ? span : nil
  }

  mutating func features() -> Bool {
    guard let h = take(2) else { return false }
    var last: Range<Int>?
    for _ in 0..<Int(reader.u16(h)) {
      guard let name = text() else { return false }
      if let last, !reader.precedes(last, name) { return false }
      last = name
    }
    return true
  }

  private mutating func slot(_ limit: UInt64, width: UInt64 = 8) -> Bool {
    guard let h = take(8) else { return false }
    let rva = reader.u64(h)
    return rva % width == 0 && imageContains(limit, rva, width)
  }

  static func functionTag(_ tag: UInt32) -> Bool {
    if tag & 0xfffff == 0 || tag & 0xfff == 0x017 { return false }
    switch tag {
    case 0xfa1e_0ff3, 0 &- 0xfa1e_0ff3, 0xd503_241f, 0xd503_245f, 0xd503_249f,
      0xd503_24df, 0xd503_233f, 0xd503_237f:
      return false
    default: return true
    }
  }

  mutating func validate(_ kind: LoaderTableKind, count: UInt32, limit: UInt64) -> Bool {
    var relr = RelativeCursor(anchorSeen: false, nextBase: 0, bits: 0, at: 0, imageSize: limit)
    if kind == .gpu && count != 1 { return false }
    var previousField: UInt64?
    for _ in 0..<count {
      switch kind {
      case .relative:
        guard let h = take(8), relr.accept(reader.u64(h)) else { return false }
        while relr.bits != 0 { _ = relr.take() }
      case .authenticated:
        guard slot(limit), let h = take(4), Self.functionTag(reader.u32(h)) else { return false }
      case .imports:
        guard slot(limit), let h = take(22) else { return false }
        let sym = reader.bytes[h]
        let module = reader.bytes[h + 1]
        let uuid = reader.u64(h + 2) | reader.u64(h + 10)
        let tag = reader.u32(h + 18)
        guard sym <= 1, module <= 1, (uuid != 0) == (module == 0),
          sym == 0 ? Self.functionTag(tag) : tag == 0,
          text() != nil, text() != nil
        else { return false }
      case .runtime:
        guard slot(limit), take(2) != nil else { return false }
      case .dispatch:
        guard slot(limit), let h = take(6), Self.functionTag(reader.u32(h)) else { return false }
        let n = reader.u16(h + 4)
        guard n > 0 else { return false }
        for _ in 0..<n {
          guard let p = take(8), reader.u64(p) < limit,
            reader.u64(p) & 15 == 0, features()
          else { return false }
        }
      case .tls:
        guard slot(limit), take(8) != nil else { return false }
      case .gpu:
        guard take(4) != nil else { return false }
      case .features:
        guard slot(limit, width: 1), text() != nil else { return false }
      case .dispatchFields:
        let field = pos
        guard slot(limit), slot(limit) else { return false }
        let rva = reader.u64(field)
        if let previousField, previousField >= rva { return false }
        previousField = rva
      }
    }
    return pos == end
  }
}

/// Decode only from a stable, pinned snapshot. No relocations are performed.
public func inspectLoaderRecords(_ section: UnsafeRawBufferPointer, addressLimit: UInt64)
  -> LoaderDirectory?
{
  let r = ELFReader(bytes: section)
  guard section.count >= 144, r.u32(0) == 0x3144_4c54,
    Int(r.u32(8)) == section.count, r.u32(12) == 0
  else { return nil }
  let n = Int(r.u16(6))
  guard (r.u16(4) == 1 && n == 8) || (r.u16(4) == 2 && n == 9),
    section.count >= 16 + 16 * n else { return nil }
  var end = 16 + 16 * n
  for i in 0..<n {
    let t = r.table(i)
    guard r.u32(28 + i * 16) == 0, t.bytes.lowerBound == end, t.bytes.upperBound <= section.count,
      let kind = LoaderTableKind(rawValue: i)
    else { return nil }
    end = t.bytes.upperBound
    var c = WireCursor(reader: r, pos: t.bytes.lowerBound, end: end)
    guard kind != .dispatchFields || t.count > 0,
      c.validate(kind, count: t.count, limit: addressLimit) else { return nil }
  }
  return end == section.count ? LoaderDirectory(r) : nil
}
