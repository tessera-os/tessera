// Offsets refer to the same immutable snapshot, not its virtual address.
public struct ImageNotes {
  public fileprivate(set) var buildID: Range<Int>?
  public fileprivate(set) var signature: Range<Int>?
  public fileprivate(set) var entitlements: Range<Int>?
  public fileprivate(set) var train: Range<Int>?
  public fileprivate(set) var target: Range<Int>?
  public fileprivate(set) var finalizer: Range<Int>?
  public fileprivate(set) var profile: Range<Int>?

  fileprivate mutating func capture(_ kind: UInt32, _ extent: Range<Int>) -> Bool {
    guard (1...7).contains(kind) else { return true }
    guard !extent.isEmpty else { return false }
    switch kind {
    case 1 where buildID == nil && extent.count == 32: buildID = extent
    case 2 where signature == nil: signature = extent
    case 3 where entitlements == nil: entitlements = extent
    case 4 where train == nil: train = extent
    case 5 where target == nil: target = extent
    case 6 where finalizer == nil: finalizer = extent
    case 7 where profile == nil: profile = extent
    default: return false
    }
    return true
  }
}

public struct InspectedImage {
  public let entry: UInt64
  public let notes: ImageNotes
  public let programHeaders: Range<Int>
}

private struct ELFReader {
  let bytes: UnsafeRawBufferPointer
  // Every access below lies within a previously bounded header, segment
  // or note. ELF records need not be machine-aligned in the capture.
  func u16(_ at: Int) -> UInt16 {
    UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt16.self))
  }
  func u32(_ at: Int) -> UInt32 {
    UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
  }
  func u64(_ at: Int) -> UInt64 {
    UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt64.self))
  }

  func readNotes(_ extent: Range<Int>, _ notes: inout ImageNotes) -> Bool {
    var pos = extent.lowerBound
    let end = extent.upperBound
    while pos < end {
      guard end - pos >= 12 else { return false }
      let names = Int(u32(pos))
      let size = Int(u32(pos + 4))
      let kind = u32(pos + 8)
      pos += 12
      let namePad = (names + 3) & ~3
      let descPad = (size + 3) & ~3
      guard namePad + descPad <= end - pos else { return false }
      if names == 8 && u64(pos) == 0x0061_7265_7373_6554 {
        let desc = pos + namePad
        guard notes.capture(kind, desc..<(desc + size)) else { return false }
      }
      pos += namePad + descPad
    }
    return true
  }
}

/// Structural preflight only: do not publish an executable mapping before
/// verifying the returned notes and page contents against the trust store.
public func inspectELF(
  _ bytes: UnsafeRawBufferPointer, target: UInt16, addressLimit: UInt64,
  finalized: Bool, requiresEntry: Bool
) -> InspectedImage? {
  guard bytes.count >= 64 else { return nil }
  let r = ELFReader(bytes: bytes)
  let header = ImageHeader(
    magic: r.u32(0), wordClass: bytes[4], encoding: bytes[5], identVersion: bytes[6],
    version: r.u32(20), kind: r.u16(16), machine: r.u16(18), headerBytes: r.u16(52),
    programOffset: r.u64(32), entryBytes: r.u16(54), count: r.u16(56))
  let size = UInt64(bytes.count)
  guard header.accepts(target, size) else { return nil }
  let entry = r.u64(24)
  var mappedEntry = !requiresEntry && entry == 0
  var noteBudget = size
  var notes = ImageNotes()
  var order = LoadOrder(afterLastPage: 0, seen: false)
  let start = Int(header.programOffset)
  let end = start + Int(header.count) * 56
  for at in stride(from: start, to: end, by: 56) {
    let kind = r.u32(at)
    if forbiddenProgramHeader(kind) { return nil }
    let offset = r.u64(at + 8)
    let length = r.u64(at + 32)
    switch kind {
    case 1:
      let segment = LoadSegment(
        fileOffset: offset, fileBytes: length, virtualAddress: r.u64(at + 16),
        memoryBytes: r.u64(at + 40), alignment: r.u64(at + 48), flags: r.u32(at + 4))
      guard order.append(segment, target, size, addressLimit) else { return nil }
      if segment.flags & 1 != 0 && entry >= segment.virtualAddress
        && entry - segment.virtualAddress < length
      {
        mappedEntry = true
      }
    case 4:
      guard offset & 3 == 0, imageContains(size, offset, length), length <= noteBudget,
        r.readNotes(Int(offset)..<Int(offset + length), &notes)
      else { return nil }
      noteBudget -= length
    default: break
    }
  }
  guard order.seen, mappedEntry, notes.buildID != nil, notes.signature != nil,
    notes.entitlements != nil, notes.train != nil, notes.target != nil, notes.profile != nil,
    !finalized || notes.finalizer != nil
  else { return nil }
  return InspectedImage(entry: entry, notes: notes, programHeaders: start..<end)
}
