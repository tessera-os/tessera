import TarwinArchAarch64
import TarwinLoader
import TarwinW0Verify

/// Only an unpublished address space. Keep the backing pinned and private;
/// PCR/log publication, thread creation, GCS and activation are separate.
public struct W1PrivateImages: ~Copyable {
  public var tables: ArmUserTranslation
  public let processCode, libraryCode: Range<UInt64>
  /// Includes page tables. The caller must pin at least this prefix.
  public let usedBytes: Int
}

private func disjoint(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
  guard let x = a.baseAddress, let y = b.baseAddress else { return false }
  let u = UInt(bitPattern: x)
  let v = UInt(bitPattern: y)
  return u <= v ? UInt(a.count) <= v - u : UInt(b.count) <= u - v
}

struct W1FramePool {
  let memory: UnsafeMutableRawBufferPointer
  let physical: UInt64
  var used = 0
  private(set) var slotOffset: Int?

  /// This pool is a fresh contiguous run. Issue each physical frame exactly
  /// once; neither an image hole nor a second mapping gets an alias.
  mutating func stage(
    file: UnsafeRawBufferPointer, image: InspectedImage,
    reservation: Range<UInt64>, rx: W1ExecutablePages, slot: UInt64?,
    nodes: UnsafeBufferPointer<BlakeCv>, witnesses: UnsafeMutableRawBufferPointer,
    tables: inout ArmUserTranslation, cleanToPoU: (UnsafeRawBufferPointer) -> Bool
  ) -> Bool {
    let size: UInt64 = 16384
    guard let source = file.baseAddress else { return false }
    for h in stride(
      from: image.programHeaders.lowerBound, to: image.programHeaders.upperBound, by: 56)
    {
      func u32(_ off: Int) -> UInt32 {
        .init(littleEndian: file.loadUnaligned(fromByteOffset: h + off, as: UInt32.self))
      }
      func u64(_ off: Int) -> UInt64 {
        .init(littleEndian: file.loadUnaligned(fromByteOffset: h + off, as: UInt64.self))
      }
      if u32(0) != 1 { continue }
      let permission = u32(4)
      let offset = u64(8)
      let rva = u64(16)
      let count = u64(32)
      guard permission == 4 || permission == 5 || (permission == 6 && slot != nil),
        count != 0, count == u64(40), (offset | rva) & (size - 1) == 0,
        imageContains(UInt64(file.count), offset, count),
        imageContains(reservation.upperBound - reservation.lowerBound, rva, count)
      else { return false }
      var n: UInt64 = 0
      while n < count {
        guard used <= memory.count - Int(size) else { return false }
        let va = reservation.lowerBound + rva + n
        let pa = physical + UInt64(used)
        let frame = UnsafeMutableRawBufferPointer(rebasing: memory[used..<used + Int(size)])
        if permission == 5 {
          guard
            rx.install(
              page: va, physical: pa, frame: frame, nodes: nodes,
              witnesses: witnesses, tables: &tables, cleanToPoU: cleanToPoU)
          else { return false }
        } else {
          // Non-executable data comes directly from the immutable pinned
          // member. Zero all padding; never copy the next ELF record.
          frame.initializeMemory(as: UInt8.self, repeating: 0)
          frame.baseAddress!.copyMemory(
            from: source + Int(offset + n), byteCount: Int(min(size, count - n)))
          guard tables.insert(virtual: va, physical: pa, write: permission == 6, execute: false)
          else { return false }
          if let slot, slot >= va && slot - va < size {
            guard permission == 6, slotOffset == nil else { return false }
            slotOffset = used
          }
        }
        n += size
        used += Int(size)
      }
    }
    return true
  }
}

/// Hold the committed reservations and original immutable archive. Supply one
/// exclusive contiguous run of normal RAM at `physical` and disjoint scratch.
/// No frame, table, scratch or archive may alias physically, including DMA.
/// On failure no root escapes; erase any staged image pages and descriptors.
@unsafe public func preparePrivateW1Images(
  _ set: borrowing W1BootSet, plan: W1AddressPlan,
  archive: UnsafeRawBufferPointer, storage: UnsafeMutableRawBufferPointer,
  physical: UInt64, tableBytes: Int, nodes: UnsafeMutableBufferPointer<BlakeCv>,
  witnesses: UnsafeMutableRawBufferPointer, cleanToPoU: (UnsafeRawBufferPointer) -> Bool,
  signImport: (UInt64, UInt64) -> UInt64?
) -> W1PrivateImages? {
  let ram = UnsafeRawBufferPointer(storage)
  let cache = UnsafeRawBufferPointer(nodes)
  let proof = UnsafeRawBufferPointer(witnesses)
  guard tableBytes >= 16384, tableBytes < storage.count, (tableBytes | storage.count) & 16383 == 0,
    physical != 0, physical & 16383 == 0, physical < 1 << 48,
    UInt64(storage.count) <= (1 << 48) - physical,
    !plan.processReservation.overlaps(plan.libraryReservation),
    disjoint(ram, cache), disjoint(ram, proof), disjoint(cache, proof),
    disjoint(archive, cache), disjoint(archive, proof),
    exactMember(set.process.bytes, in: archive, at: set.process.range, excluding: storage),
    exactMember(set.library.bytes, in: archive, at: set.library.range, excluding: storage),
    var tables = ArmUserTranslation(
      backing: .init(rebasing: storage[..<tableBytes]), physical: physical)
  else { return nil }
  var finished = false
  defer { if !finished { storage.initializeMemory(as: UInt8.self, repeating: 0) } }
  var pool = W1FramePool(
    memory: .init(rebasing: storage[tableBytes...]), physical: physical + UInt64(tableBytes))
  func stage(_ role: W1CodeRole, _ tables: inout ArmUserTranslation, _ pool: inout W1FramePool)
    -> Range<UInt64>?
  {
    let initMember = role == .process
    let member = initMember ? set.process : set.library
    guard let rx = W1ExecutablePages(set, plan: plan, role: role, nodes: nodes),
      pool.stage(
        file: member.bytes, image: member.layout.image,
        reservation: initMember ? plan.processReservation : plan.libraryReservation,
        rx: rx, slot: initMember ? plan.slotAddress : nil, nodes: .init(nodes),
        witnesses: witnesses,
        tables: &tables, cleanToPoU: cleanToPoU)
    else { return nil }
    return rx.code
  }
  guard let process = stage(.process, &tables, &pool),
    let library = stage(.library, &tables, &pool), let slot = pool.slotOffset,
    bindAuthorizedQEMUImport(
      set, plan: plan, tables: &tables,
      frame: .init(rebasing: pool.memory[slot..<slot + 16384]),
      physical: pool.physical + UInt64(slot),
      sign: signImport)
  else { return nil }
  finished = true
  return W1PrivateImages(
    tables: consume tables, processCode: process, libraryCode: library,
    usedBytes: tableBytes + pool.used)
}
