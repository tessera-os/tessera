// §23 normal RAM, 4 KiB leaves, no large pages, A/D logging or MMIO leaves.
// RV64 Sv48x4, AMD NPT (NXE active), and Intel EPT (WB, four-level walk).
public enum GuestRadixFormat {
  case sv48x4, npt, ept

  fileprivate var rootFrames: Int { self == .sv48x4 ? 4 : 1 }
  public var ipaLimit: UInt64 { 1 << (self == .sv48x4 ? 50 : 48) }

  fileprivate func branch(_ pa: UInt64) -> UInt64 {
    self == .sv48x4 ? (pa >> 2) | 1 : pa | 7
  }
  fileprivate func leaf(_ pa: UInt64, _ rights: UInt64) -> UInt64 {
    switch self {
    case .sv48x4:
      // G-stage accesses are checked as U-mode. Set A/D in software.
      return (pa >> 2) | 0x51 | (rights << 1) | (rights == 3 ? 0x80 : 0)
    case .npt:
      return pa | 5 | (rights == 3 ? 2 : 0) | (rights == 5 ? 0 : (1 << 63))
    case .ept:
      return pa | rights | (6 << 3)
    }
  }
}

public struct GuestRadixTables: ~Copyable {
  public let format: GuestRadixFormat
  public let rootPA: UInt64
  private let words: UnsafeMutableBufferPointer<UInt64>
  private let capacity: Int
  private var next: Int

  // Caller owns the contiguous coherent arena (PA == physicalBase), kept
  // private/pinned until every vCPU is stopped and all translations retired.
  // Root and all initially empty lower tables are zeroed before publication.
  @unsafe public init?(
    format: GuestRadixFormat, arena: UnsafeMutableBufferPointer<UInt64>,
    physicalBase: UInt64
  ) {
    let frames = arena.count / 512
    guard arena.baseAddress != nil, arena.count % 512 == 0,
      frames >= format.rootFrames + 3, frames <= 65536,
      physicalBase % UInt64(4096 * format.rootFrames) == 0, physicalBase < 1 << 48,
      UInt64(frames) << 12 <= (1 << 48) - physicalBase
    else { return nil }
    self.format = format
    rootPA = physicalBase
    capacity = frames
    next = format.rootFrames
    words = arena
    for i in arena.indices { words[i] = 0 }
  }

  private func slot(_ ipa: UInt64, _ depth: Int, _ table: Int) -> Int {
    let mask = depth == 0 ? format.rootFrames * 512 - 1 : 511
    return table * 512 + (Int(ipa >> (39 - depth * 9)) & mask)
  }

  private func child(_ descriptor: UInt64) -> Int {
    if descriptor == 0 { return 0 }
    // NPT hardware may set A on visited non-leaves; EPT A/D is disabled.
    let d = format == .npt ? descriptor & ~0x20 : descriptor
    let pa = format == .sv48x4 ? (d >> 10) << 12 : d & ~0xfff
    guard d == format.branch(pa), pa >= rootPA + UInt64(format.rootFrames * 4096),
      pa < rootPA + UInt64(next * 4096)
    else { return -1 }
    return Int((pa - rootPA) >> 12)
  }

  private func valid(_ base: UInt64, _ count: UInt64, _ limit: UInt64) -> Bool {
    count != 0 && (base | count) & 0xfff == 0 && base < limit && count <= limit - base
  }

  // Hold the VM writer lock and stop all walkers. Install is all-or-nothing;
  // preflight counts each missing prefix once in ascending page order.
  public mutating func install(ipa: UInt64, bytes: UInt64, pinnedPA: UInt64, permissions: UInt64)
    -> Bool
  {
    guard valid(ipa, bytes, format.ipaLimit), valid(pinnedPA, bytes, 1 << 48),
      permissions == 1 || permissions == 3 || permissions == 5,
      pinnedPA + bytes <= rootPA || pinnedPA >= rootPA + UInt64(capacity * 4096)
    else { return false }
    let end = ipa + bytes
    var need = 0
    var g = ipa
    while g < end {
      var table = 0
      var missing = false
      for depth in 0..<3 {
        if !missing {
          table = child(words[slot(g, depth, table)])
          if table < 0 { return false }
          missing = table == 0
        }
        if missing && (g == ipa || (g >> (39 - depth * 9)) != ((g - 4096) >> (39 - depth * 9))) {
          need += 1
          if need > capacity - next { return false }
        }
      }
      if !missing && words[slot(g, 3, table)] != 0 { return false }
      g += 4096
    }
    g = ipa
    while g < end {
      var table = 0
      for depth in 0..<3 {
        let i = slot(g, depth, table)
        table = child(words[i])
        if table == 0 {
          table = next
          next += 1
          words[i] = format.branch(rootPA + UInt64(table * 4096))
        }
      }
      words[slot(g, 3, table)] = format.leaf(pinnedPA + (g - ipa), permissions)
      g += 4096
    }
    return true
  }

  // No branch pages are recycled while walkers/TLBs can refer to the root.
  // Use the extent lifecycle to invalidate before returning a backing page.
  public mutating func detach(ipa: UInt64, bytes: UInt64) -> Bool {
    guard valid(ipa, bytes, format.ipaLimit) else { return false }
    for commit in 0...1 {
      var g = ipa
      while g < ipa + bytes {
        var table = 0
        for depth in 0..<3 {
          table = child(words[slot(g, depth, table)])
          if table <= 0 { return false }
        }
        let leaf = slot(g, 3, table)
        if words[leaf] == 0 { return false }
        if commit == 1 { words[leaf] = 0 }
        g += 4096
      }
    }
    return true
  }
}
