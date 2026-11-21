public enum EarlyUserRole {
  /// The type tag of the process runtime's real entry, independently supplied
  /// by the producer. Not the kernel handoff tag.
  case initialProcess(entryTag: UInt32)
  case systemLibrary
}

public struct EarlyUserImage {
  public let image: InspectedImage
  /// Unrounded file-backed RX bytes only, relative to the image base.
  public let code: Range<UInt64>
}

/// Restricted QEMU W1 input to the loader, never authority to run. The single
/// private RELRO segment in init exists solely for its eager framework import.
public func inspectEarlyUserImage(
  _ file: UnsafeRawBufferPointer, role: EarlyUserRole,
  machine: UInt16, train: (UInt8, UInt8, UInt8), tir: (UInt8, UInt8, UInt8), addressLimit: UInt64,
  scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> EarlyUserImage? {
  let entryTag: UInt32?
  switch role {
  case .initialProcess(let tag):
    guard WireCursor.functionTag(tag) else { return nil }
    entryTag = tag
  case .systemLibrary: entryTag = nil
  }
  guard machine == ElfMachine.aarch64,
    let (image, d, section) = parsedSigningCandidate(
      file, machine: machine, addressLimit: addressLimit,
      finalized: false, requiresEntry: entryTag != nil, scratch: scratch)
  else { return nil }
  let r = ELFReader(bytes: file)
  let n = image.notes
  guard let p = n.profile, r.u16(p.lowerBound) == (entryTag == nil ? 0x101 : 1),
    let grants = n.entitlements, r.nameEquals(grants, "[]"), let versions = n.train,
    let target = n.target, matchesW0Baseline(.init(rebasing: file[target]), machine: machine),
    d[.imports].count == (entryTag == nil ? 0 : 1), d[.relative].count == 0,
    d[.authenticated].count == 0, d[.runtime].count == 0, d[.dispatch].count == 0,
    d[.tls].count == 0, d[.features].count == 0,
    r.u32(section.lowerBound + d[.gpu].bytes.lowerBound) == 0
  else { return nil }
  let v = versions.lowerBound
  guard (file[v], file[v + 1], file[v + 2]) == train,
    (file[v + 3], file[v + 4], file[v + 5]) == tir,
    (file[v + 6], file[v + 7], file[v + 8]) == train
  else { return nil }
  var rx: Range<UInt64>?
  var writable: Int?
  var relro: Int?
  var note = false
  for h in stride(
    from: image.programHeaders.lowerBound, to: image.programHeaders.upperBound, by: 56)
  {
    let va = r.u64(h + 16)
    let size = r.u64(h + 32)
    switch r.u32(h) {
    case 1:
      guard size != 0, size == r.u64(h + 40) else { return nil }
      switch r.u32(h + 4) {
      case 4: break
      case 5:
        guard rx == nil else { return nil }
        rx = va..<va + size
      case 6:
        guard writable == nil, entryTag != nil else { return nil }
        writable = h
      default: return nil
      }
    case 4:
      guard !note, va == 0 else { return nil }
      note = true
    case 0x6474_e552:
      guard relro == nil, entryTag != nil else { return nil }
      relro = h
    default: return nil
    }
  }
  guard let rx, note else { return nil }
  if let tag = entryTag {
    var hint: Int?
    guard let w = writable, let h = relro,
      r.u64(w + 8) == r.u64(h + 8), r.u64(w + 16) == r.u64(h + 16),
      r.u64(w + 32) == r.u64(h + 32), r.u64(w + 40) == r.u64(h + 40),
      r.validLocalEntry(
        image.entry, tag: tag, machine: machine, programs: image.programHeaders, hint: &hint)
    else { return nil }
    let start = section.lowerBound + d[.imports].bytes.lowerBound
    var c = WireCursor(
      reader: r, pos: start + 30, end: section.lowerBound + d[.imports].bytes.upperBound)
    guard r.u16(start + 8) == 0, let mod = c.text(), r.nameEquals(mod, "LibTessera") else {
      return nil
    }
  } else {
    guard image.entry == 0,
      case .found = r.findMetadataSection(
        ".ridlmeta", programs: image.programHeaders, unloaded: true)
    else { return nil }
  }
  return EarlyUserImage(image: image, code: rx)
}
