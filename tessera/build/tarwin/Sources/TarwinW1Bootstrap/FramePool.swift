import TarwinArchAarch64
import TarwinLoader
import TarwinW0Verify

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

extension W1FramePool {
  mutating func stageMember(_ role: W1CodeRole, set: borrowing W1BootSet, plan: W1AddressPlan,
    nodes: UnsafeMutableBufferPointer<BlakeCv>, witnesses: UnsafeMutableRawBufferPointer,
    tables: inout ArmUserTranslation, cleanToPoU: (UnsafeRawBufferPointer) -> Bool
  ) -> Range<UInt64>? {
    let process = role == .process
    let member = process ? set.process : set.library
    guard let rx = W1ExecutablePages(set, plan: plan, role: role, nodes: nodes),
      stage(file: member.bytes, image: member.layout.image,
        reservation: process ? plan.processReservation : plan.libraryReservation,
        rx: rx, slot: process ? plan.slotAddress : nil, nodes: .init(nodes),
        witnesses: witnesses, tables: &tables, cleanToPoU: cleanToPoU)
    else { return nil }
    return rx.code
  }
}
