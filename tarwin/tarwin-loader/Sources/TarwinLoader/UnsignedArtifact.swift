/// Linker interchange result, deliberately not an InspectedImage. No signing
/// trust, launch decision, writable mapping or resolved import follows from it.
public struct UnsignedArtifact {
  public let buildID: BlakeCv
  public let notes: ImageNotes
  public let records: LoaderDirectory
  public let section: Range<Int>
}

private struct JSONNameBytes {
  let r: ELFReader
  var pos: Int
  let end: Int

  private func hex(_ byte: UInt8) -> UInt8? {
    if (48...57).contains(byte) { return byte - 48 }
    if (97...102).contains(byte) { return byte - 87 }
    return nil
  }

  // Read one decoded byte of a canonical RFC 8785 string. The caller
  // identifies the end quote and validates UTF-8 over the encoded span.
  mutating func next() -> UInt8? {
    guard pos < end else { return nil }
    let c = r.bytes[pos]
    pos += 1
    if c != 92 { return c >= 32 && c != 34 ? c : nil }
    guard pos < end else { return nil }
    let escape = r.bytes[pos]
    pos += 1
    switch escape {
    case 34, 92: return escape
    case 98: return 8
    case 116: return 9
    case 110: return 10
    case 102: return 12
    case 114: return 13
    case 117:
      guard end - pos >= 4, r.bytes[pos] == 48, r.bytes[pos + 1] == 48,
        let hi = hex(r.bytes[pos + 2]), let lo = hex(r.bytes[pos + 3])
      else { return nil }
      let v = hi << 4 | lo
      pos += 4
      switch v {
      case 0...7, 11, 14...31: return v
      default: return nil
      }
    default: return nil
    }
  }
}

extension ELFReader {
  func entitlementList(_ ext: Range<Int>) -> Bool {
    guard ext.count >= 2, bytes[ext.lowerBound] == 91, bytes[ext.upperBound - 1] == 93 else {
      return false
    }
    let end = ext.upperBound - 1
    var pos = ext.lowerBound + 1
    if pos == end { return true }
    var previous: Range<Int>?
    while pos < end {
      guard bytes[pos] == 34 else { return false }
      let start = pos + 1
      var scan = JSONNameBytes(r: self, pos: start, end: end)
      while scan.pos < end && bytes[scan.pos] != 34 {
        guard scan.next() != nil else { return false }
      }
      let name = start..<scan.pos
      guard scan.pos < end, wireText(name) else { return false }
      if let old = previous {
        var a = JSONNameBytes(r: self, pos: old.lowerBound, end: old.upperBound)
        var b = JSONNameBytes(r: self, pos: start, end: scan.pos)
        var less = false
        while let bv = b.next() {
          guard let av = a.next() else {
            less = true
            break
          }
          if av != bv {
            less = av < bv
            break
          }
        }
        guard less else { return false }
      }
      previous = name
      pos = scan.pos + 1
      if pos == end { return true }
      guard bytes[pos] == 44 else { return false }
      pos += 1
    }
    return false
  }

  func wireVersion(_ at: Int) -> Bool {
    (1...99).contains(bytes[at]) && (1...12).contains(bytes[at + 1])
      && (1...5).contains(bytes[at + 2])
  }

  func validTarget(_ extent: Range<Int>, machine: UInt16) -> Bool {
    var c = WireCursor(reader: self, pos: extent.lowerBound, end: extent.upperBound)
    guard let name = c.text(), c.features(), let at = c.take(2), c.pos == c.end else {
      return false
    }
    var split = name.lowerBound
    while split < name.upperBound && bytes[split] != 43 && bytes[split] != 58 { split += 1 }
    let base = name.lowerBound..<split
    if name == base
      && (nameEquals(base, "aarch64.base") || nameEquals(base, "x64.v3")
        || nameEquals(base, "rv64.base"))
    {
      return matchesW0Baseline(.init(rebasing: bytes[extent]), machine: machine)
    }
    // Full modifier and feature support must be checked against the CPU at launch.
    var scale: UInt8
    switch machine {
    case ElfMachine.aarch64:
      if nameEquals(base, "aarch64.v9") {
        scale = 0
      } else if nameEquals(base, "aarch64.base") || nameEquals(base, "aarch64.v86") {
        scale = 1
      } else {
        return false
      }
    case ElfMachine.x64:
      if nameEquals(base, "x64.v3") {
        scale = 2
      } else if nameEquals(base, "x64.v4") || nameEquals(base, "x64.avx10_2")
        || nameEquals(base, "x64.apx")
      {
        scale = 4
      } else {
        return false
      }
    case ElfMachine.rv64:
      guard nameEquals(base, "rv64.base") || nameEquals(base, "rv64.zvk") else { return false }
      scale = 0
    default: return false
    }
    return bytes[at] == (scale == 0 ? 0 : 1) && bytes[at + 1] == scale
  }
}

/// Size the caller's hash/dispatch workspace in BlakeCv elements. This
/// checks the directory's bounds, not the file's ID or semantic validity.
public func unsignedInspectionScratchCount(
  _ bytes: UnsafeRawBufferPointer, machine: UInt16, addressLimit: UInt64,
  finalized: Bool, requiresEntry: Bool
) -> Int? {
  guard let image = inspectLayout(bytes, target: machine, addressLimit: addressLimit,
    finalized: finalized, requiresEntry: requiresEntry, requiresLoaderRecords: true),
    image.notes.signature == nil, let section = image.loaderRecords,
    let dir = inspectLoaderRecords(.init(rebasing: bytes[section]), addressLimit: addressLimit)
  else { return nil }
  let size = dir[.dispatchFields].count == 0 ? 0 : 8 * Int(dir[.dispatch].count)
  let stride = MemoryLayout<BlakeCv>.stride
  return max(54, (size + stride - 1) / stride)
}

/// Scratch must be disjoint from the immutable file and sufficient for the
/// image hash and, in TLD1 v2, one UInt64 per Dispatch record (reused).
public func inspectUnsignedArtifact(
  _ bytes: UnsafeRawBufferPointer, machine: UInt16, addressLimit: UInt64,
  finalized: Bool, requiresEntry: Bool, scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> UnsignedArtifact? {
  guard
    let (image, directory, section, root) = parsedUnsignedArtifact(
      bytes, machine: machine,
      addressLimit: addressLimit, finalized: finalized, requiresEntry: requiresEntry,
      scratch: scratch)
  else { return nil }
  return UnsignedArtifact(buildID: root, notes: image.notes, records: directory, section: section)
}

func parsedUnsignedArtifact(
  _ bytes: UnsafeRawBufferPointer, machine: UInt16, addressLimit: UInt64,
  finalized: Bool, requiresEntry: Bool, scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> (InspectedImage, LoaderDirectory, Range<Int>, BlakeCv)? {
  guard
    let image = inspectLayout(
      bytes, target: machine, addressLimit: addressLimit,
      finalized: finalized, requiresEntry: requiresEntry, requiresLoaderRecords: true),
    image.notes.signature == nil, let id = image.notes.buildID,
    let root = unsignedBuildID(bytes, descriptor: id, scratch: scratch),
    let parsed = validatedMetadata(
      bytes, image: image, machine: machine, addressLimit: addressLimit, finalized: finalized,
      root: root, scratch: UnsafeMutableRawBufferPointer(scratch))
  else { return nil }
  return (image, parsed.0, parsed.1, root)
}

func validatedMetadata(
  _ bytes: UnsafeRawBufferPointer, image: InspectedImage, machine: UInt16, addressLimit: UInt64,
  finalized: Bool, root: BlakeCv, scratch: UnsafeMutableRawBufferPointer
) -> (LoaderDirectory, Range<Int>)? {
  guard let id = image.notes.buildID, let section = image.loaderRecords,
    let ent = image.notes.entitlements, let train = image.notes.train,
    let target = image.notes.target,
    let profile = image.notes.profile
  else { return nil }
  let r = ELFReader(bytes: bytes)
  guard train.count == 9, r.wireVersion(train.lowerBound), r.wireVersion(train.lowerBound + 3),
    r.wireVersion(train.lowerBound + 6), r.validTarget(target, machine: machine),
    r.entitlementList(ent),
    profile.count == 2,
    finalized ? image.notes.finalizer?.count == 64 : image.notes.finalizer == nil
  else { return nil }
  let kind = bytes[profile.lowerBound + 1]
  let p = bytes[profile.lowerBound]
  guard (kind <= 2 && p <= 1) || (kind == 3 && p == 2) || (kind == 4 && p == 3) else { return nil }
  for at in stride(
    from: image.programHeaders.lowerBound, to: image.programHeaders.upperBound, by: 56)
  where r.u32(at) == 1 && r.u64(at + 32) != 0 {
    let end = r.u64(at + 8) + r.u64(at + 32)
    let page = imagePage(machine)
    // Note header (12) plus "Tessera\0" (8) precede the descriptor.
    guard UInt64(id.lowerBound - 20) >= ((end + page - 1) & ~(page - 1)) else { return nil }
    if let sig = image.notes.signature,
      UInt64(sig.lowerBound - 20) < ((end + page - 1) & ~(page - 1))
    {
      return nil
    }
  }
  guard
    let records = inspectLoaderRecords(
      UnsafeRawBufferPointer(rebasing: bytes[section]), addressLimit: addressLimit)
  else { return nil }
  guard !(p == 3 && records.hasDispatch),
    r.validImportSlots(image, directory: records, section: section, machine: machine, scratch: scratch)
  else {
    return nil
  }
  let count = r.u32(section.lowerBound + records[.gpu].bytes.lowerBound)
  switch r.findMetadataSection(".tirgpu", programs: image.programHeaders, unloaded: true) {
  case .invalid: return nil
  case .absent: guard count == 0 else { return nil }
  case .found(let gpu):
    let g = gpu.lowerBound
    guard !gpu.overlaps(section), gpu.count >= 16, r.u32(g) == 0x5550_4754,
      r.u32(g + 8) == count,
      bytes[g + 4] == bytes[train.lowerBound + 3],
      bytes[g + 5] == bytes[train.lowerBound + 4],
      bytes[g + 6] == bytes[train.lowerBound + 5]
    else { return nil }
  }
  let pId = id.lowerBound
  let expected = BlakeCv(
    w0: r.u32(pId), w1: r.u32(pId + 4), w2: r.u32(pId + 8), w3: r.u32(pId + 12),
    w4: r.u32(pId + 16), w5: r.u32(pId + 20), w6: r.u32(pId + 24), w7: r.u32(pId + 28))
  guard root.matches(expected) else { return nil }
  return (records, section)
}
