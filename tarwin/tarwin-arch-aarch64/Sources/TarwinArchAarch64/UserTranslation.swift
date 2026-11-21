/// Storage for an unpublished 16 KiB stage-1 root. No blocks, LPA2,
/// replacement or live PTE edits. Never alias or activate a root in build.
private struct ArmPrivateRoot: ~Copyable {
  private let words: UnsafeMutableBufferPointer<UInt64>
  let physicalRoot: UInt64
  private(set) var usedPages: Int

  @unsafe init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64) {
    guard let ptr = backing.baseAddress, UInt(bitPattern: ptr) & 7 == 0,
      backing.count >= 16384, backing.count & 16383 == 0,
      physical != 0, physical & 16383 == 0, physical < 1 << 48,
      UInt64(backing.count) <= (1 << 48) - physical
    else { return nil }
    // The backing is dedicated uninitialized RAM, not active translation tables.
    self.words = backing.bindMemory(to: UInt64.self)
    self.words.initialize(repeating: 0)
    self.physicalRoot = physical
    self.usedPages = 1
  }

  mutating func insert(virtual: UInt64, physical: UInt64, leaf: UInt64) -> Bool {
    guard virtual & 16383 == 0, physical != 0, leaf != 0,
      physical < physicalRoot || physical >= physicalRoot + UInt64(words.count) * 8
    else { return false }
    var table = 0
    for level in 0..<3 {
      let cell = table * 2048 + Int(armWalkIndex(virtual, level: UInt8(level)))
      let value = words[cell]
      if value != 0 {
        guard value & 16383 == 3, value >= physicalRoot + 3 else { return false }
        let child = (value - 3 - physicalRoot) >> 14
        guard child > table, child < UInt64(usedPages) else { return false }
        table = Int(child)
      } else {
        // Preflight every missing table before changing the first descriptor.
        guard 3 - level <= words.count / 2048 - usedPages else { return false }
        table = usedPages
        usedPages += 1
        words[cell] = physicalRoot + UInt64(table * 16384) + 3
      }
    }
    let entry = table * 2048 + Int(armWalkIndex(virtual, level: 3))
    guard words[entry] == 0 else { return false }
    words[entry] = leaf
    return true
  }

  private func mutableUserDataCell(_ va: UInt64) -> Int? {
    var table = 0
    for level in 0..<3 {
      let link = words[table * 2048 + Int(armWalkIndex(va, level: UInt8(level)))]
      guard link & 16383 == 3, link >= physicalRoot + 3 else { return nil }
      let child = (link - 3 - physicalRoot) >> 14
      guard child > table, child < UInt64(usedPages) else { return nil }
      table = Int(child)
    }
    let cell = table * 2048 + Int(armWalkIndex(va, level: 3))
    let leaf = words[cell]
    let physical = leaf & 0x0000_ffff_ffff_c000
    guard physical != 0, leaf == armUserPage(physical, write: true, execute: false, lpa2: false)
    else { return nil }
    return cell
  }

  mutating func sealUserData(_ range: Range<UInt64>) -> Bool {
    let lo = range.lowerBound, hi = range.upperBound
    guard lo < hi, lo >= 1 << 32, hi <= 1 << 47, (lo | hi) & 16383 == 0,
      (hi - lo) >> 14 <= UInt64(words.count) else { return false }
    var va = lo
    while va < hi {
      guard mutableUserDataCell(va) != nil else { return false }
      va += 16384
    }
    va = lo
    while va < hi {
      // The root is exclusively held; only the AP[2] bit of leaves changes.
      words[mutableUserDataCell(va)!] |= 1 << 7
      va += 16384
    }
    return true
  }
}

/// A process-private lower-half TTBR0 root. The caller owns and pins the
/// arena and frames and enforces rights, including aliases in other mappings.
public struct ArmUserTranslation: ~Copyable {
  private var root: ArmPrivateRoot
  public var physicalRoot: UInt64 { root.physicalRoot }
  public var usedPages: Int { root.usedPages }

  @unsafe public init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64) {
    guard let root = ArmPrivateRoot(backing: backing, physical: physical) else { return nil }
    self.root = root
  }

  public mutating func insert(virtual: UInt64, physical: UInt64, write: Bool, execute: Bool) -> Bool
  {
    guard virtual < 1 << 47, virtual >= 1 << 32 else { return false }
    let leaf = armUserPage(physical, write: write, execute: execute, lpa2: false)
    guard leaf != 0 else { return false }
    return root.insert(
      virtual: virtual, physical: physical,
      leaf: leaf | (execute ? (UInt64(1) << 50) : 0))
  }

  /// Seal complete RELRO pages in an exclusively held, never-active root.
  /// The caller owns the frames and must exclude writable aliases and DMA.
  /// No TLB invalidation: this is not an active address-space edit.
  public mutating func sealReadOnly(_ range: Range<UInt64>) -> Bool {
    root.sealUserData(range)
  }
}

/// A separate upper-half TTBR1 root; all leaves deny EL0, including EL0
/// instruction fetch. Caller pins and owns the arena and all mapped frames.
public struct ArmKernelTranslation: ~Copyable {
  private var root: ArmPrivateRoot
  public var physicalRoot: UInt64 { root.physicalRoot }
  public var usedPages: Int { root.usedPages }

  @unsafe public init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64) {
    guard let root = ArmPrivateRoot(backing: backing, physical: physical) else { return nil }
    self.root = root
  }

  public mutating func insert(virtual: UInt64, physical: UInt64, write: Bool, execute: Bool) -> Bool
  {
    guard virtual >= 0xffff_8000_0000_0000, physical & 16383 == 0, physical < 1 << 48,
      !(write && execute)
    else { return false }
    let ap: UInt64 = write ? 0 : 0x80
    let fetch = UInt64(1) << (execute ? 50 : 53)  // guarded code or PXN
    let leaf = physical | 0x703 | ap | fetch | (1 << 54)
    return root.insert(virtual: virtual, physical: physical, leaf: leaf)
  }
}
