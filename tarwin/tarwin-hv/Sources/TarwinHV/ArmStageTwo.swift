// §23.2, AArch64: normal guest RAM only, 16 KiB granules, L2/L3,
// 36-bit IPA, 40-bit output, no LPA2, hardware dirty update or block leaves.
public struct ArmStageTwo: ~Copyable {
  public static var pageSize: UInt64 { 1 << 14 }
  public static var ipaLimit: UInt64 { 1 << 36 }
  public static var outputLimit: UInt64 { 1 << 40 }
  // RES1, PS=40, TG0=16K, SH0=inner, ORGN0/IRGN0=WBWA, SL0=L2, T0SZ=28.
  public static var vtcr: UInt64 { 0x8002_b55c }
  public let rootPA: UInt64
  private let words: UnsafeMutableBufferPointer<UInt64>
  private let pages: Int
  private var next = 1

  // Unsafe boundary: the caller exclusively owns a pinned contiguous table
  // arena for this VM's lifetime. 'words' is its coherent, writable alias;
  // CPUs that can walk this root must be stopped throughout every edit.
  // No referenced table is recycled until VM teardown and completed shootdown.
  @unsafe public init?(arena: UnsafeMutableBufferPointer<UInt64>, physicalBase: UInt64) {
    guard arena.baseAddress != nil, arena.count >= 4096, arena.count % 2048 == 0,
      arena.count / 2048 <= 2049, physicalBase % Self.pageSize == 0,
      physicalBase < Self.outputLimit, UInt64(arena.count) * 8 <= Self.outputLimit - physicalBase
    else { return nil }
    words = arena
    pages = arena.count / 2048
    rootPA = physicalBase
    for i in 0..<arena.count { words[i] = 0 }
  }

  // Zero is a missing subtree; -1 is malformed. Never follow an address
  // outside the privately issued part of this arena, including the root.
  private func subtree(_ index: Int) -> Int {
    let d = words[index]
    if d == 0 { return 0 }
    guard d % Self.pageSize == 3, d > rootPA + 3 else { return -1 }
    let frame = (d - rootPA) / Self.pageSize
    return frame < UInt64(next) ? Int(frame) : -1
  }

  private func valid(_ base: UInt64, _ size: UInt64, _ limit: UInt64) -> Bool {
    size != 0 && (base | size) % Self.pageSize == 0 && base < limit && size <= limit - base
  }

  // PA is supplied by the pin owner, never by a VMM. Only RO, RW and RX
  // are supported. An error changes neither the tables nor arena capacity.
  public mutating func install(ipa: UInt64, bytes: UInt64, pinnedPA: UInt64, permissions: UInt64)
    -> Bool
  {
    guard valid(ipa, bytes, Self.ipaLimit), valid(pinnedPA, bytes, Self.outputLimit),
      permissions == 1 || permissions == 3 || permissions == 5,
      pinnedPA + bytes <= rootPA || pinnedPA >= rootPA + UInt64(words.count) * 8
    else { return false }

    var missing = 0
    let first = Int(ipa >> 14)
    let end = Int((ipa + bytes) >> 14)
    for root in (first >> 11)...((end - 1) >> 11) {
      let table = subtree(root)
      if table < 0 { return false }
      if table == 0 {
        missing += 1
        if missing > pages - next { return false }
      } else {
        for p in max(first, root << 11)..<min(end, (root + 1) << 11) {
          if words[table * 2048 + p % 2048] != 0 { return false }
        }
      }
    }
    let access: UInt64 = permissions == 3 ? 0xc0 : 0x40
    let xn: UInt64 = permissions == 5 ? 0 : 1 << 54
    // AF=1, inner shareable, normal WB memory, L3 page. The caller
    // publishes these stores with a DSB before making a vCPU runnable.
    let flags = UInt64(0x73f) | access | xn
    for p in first..<end {
      let root = p >> 11
      var table = subtree(root)
      if table == 0 {
        table = next
        next += 1
        words[root] = (rootPA + UInt64(table) * Self.pageSize) | 3
      }
      words[table * 2048 + p % 2048] = (pinnedPA + UInt64(p - first) * Self.pageSize) | flags
    }
    return true
  }

  // Does not unpin or imply invalidation. GuestExtent.retire requires
  // the caller to complete stage-1+2 TLBI before releasing the pin.
  public mutating func detach(ipa: UInt64, bytes: UInt64) -> Bool {
    guard valid(ipa, bytes, Self.ipaLimit) else { return false }
    let first = Int(ipa >> 14)
    let end = Int((ipa + bytes) >> 14)
    for p in first..<end {
      let table = subtree(p >> 11)
      if table <= 0 || words[table * 2048 + p % 2048] & 3 != 3 { return false }
    }
    for p in first..<end { words[subtree(p >> 11) * 2048 + p % 2048] = 0 }
    return true
  }
}
