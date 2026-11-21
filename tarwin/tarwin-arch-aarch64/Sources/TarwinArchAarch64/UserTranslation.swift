/// Storage for an unpublished 16 KiB stage-1 root. No blocks, LPA2,
/// replacement or live PTE edits. Never alias or activate a root in build.
private struct ArmPrivateRoot: ~Copyable {
  private let words: UnsafeMutableBufferPointer<UInt64>
  let physicalRoot: UInt64
  let layout: ArmPermissionLayout
  private(set) var usedPages: Int

  @unsafe init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64, layout: ArmPermissionLayout) {
    guard let ptr = backing.baseAddress, UInt(bitPattern: ptr) & 7 == 0,
      backing.count >= 16384, backing.count & 16383 == 0,
      physical != 0, physical & 16383 == 0, physical < 1 << 48,
      UInt64(backing.count) <= (1 << 48) - physical
    else { return nil }
    // The backing is dedicated uninitialized RAM, not active translation tables.
    self.words = backing.bindMemory(to: UInt64.self)
    self.words.initialize(repeating: 0)
    self.physicalRoot = physical
    self.layout = layout
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

  // nil = corrupt path, -1 = missing intermediate table.
  private func leafCell(_ va: UInt64) -> Int? {
    var table = 0
    for level in 0..<3 {
      let link = words[table * 2048 + Int(armWalkIndex(va, level: UInt8(level)))]
      if link == 0 { return -1 }
      guard link & 16383 == 3, link >= physicalRoot + 3 else { return nil }
      let child = (link - 3 - physicalRoot) >> 14
      guard child > table, child < UInt64(usedPages) else { return nil }
      table = Int(child)
    }
    return table * 2048 + Int(armWalkIndex(va, level: 3))
  }

  private func mutableUserDataCell(_ va: UInt64) -> Int? {
    guard let cell = leafCell(va), cell >= 0 else { return nil }
    let leaf = words[cell]
    let physical = leaf & 0x0000_ffff_ffff_c000
    guard physical != 0, leaf == armUserPage(physical, write: true, execute: false, lpa2: false)
    else { return nil }
    return cell
  }

  func hasLeaf(_ va: UInt64, _ role: ArmEntryPage) -> Bool {
    guard let cell = leafCell(va) else { return false }
    let leaf = cell < 0 ? 0 : words[cell]
    if role == .guardPage { return leaf == 0 }
    let pa = leaf & 0x0000_ffff_ffff_c000
    guard pa != 0 else { return false }
    let code = role == .code
    let intended = armUserPage(pa, write: !code, execute: code, lpa2: false)
    return leaf == intended | (code ? 1 << 50 : 0)
  }

  func privateWritableFrame(_ va: UInt64) -> UInt64? {
    guard let cell = mutableUserDataCell(va) else { return nil }
    return words[cell] & 0x0000_ffff_ffff_c000
  }

  func mapsKernelData(_ va: UInt64, physical: UInt64) -> Bool {
    guard let cell = leafCell(va), cell >= 0 else { return false }
    return words[cell] == physical | 0x703 | (1 << 53) | (1 << 54)
  }

  func mapsControl(_ va: UInt64, _ pa: UInt64) -> Bool {
    let leaf = layout.controlLeaf(pa)
    guard leaf != 0, let cell = leafCell(va), cell >= 0 else { return false }
    return words[cell] == leaf
  }

  func canSeal(_ range: Range<UInt64>) -> Bool {
    let lo = range.lowerBound, hi = range.upperBound
    guard lo < hi, lo >= 1 << 32, hi <= 1 << 47, (lo | hi) & 16383 == 0,
      (hi - lo) >> 14 <= UInt64(words.count) else { return false }
    var va = lo
    while va < hi {
      guard mutableUserDataCell(va) != nil else { return false }
      va += 16384
    }
    return true
  }

  mutating func sealValidated(_ range: Range<UInt64>) {
    var va = range.lowerBound
    while va < range.upperBound {
      // PIE ignores AP[2] for base permission; select EL0 index 15 (RO)
      // rather than leaving a nominally sealed page at index 13 (RW).
      words[mutableUserDataCell(va)!] |= (1 << 7) | (layout == .guarded ? 1 << 51 : 0)
      va += 16384
    }
  }
}

/// A process-private lower-half TTBR0 root. The caller owns and pins the
/// arena and frames and enforces rights, including aliases in other mappings.
public struct ArmUserTranslation: ~Copyable {
  private var root: ArmPrivateRoot
  public var physicalRoot: UInt64 { root.physicalRoot }
  public var usedPages: Int { root.usedPages }
  public var layout: ArmPermissionLayout { root.layout }

  /// Consume the writer before exposing this root to a hardware walker.
  /// Borrowers must keep its pinned frames immutable until every CPU retires it.
  public consuming func finish() -> ArmFinishedUserRoot? {
    guard usedPages > 1 else { return nil }
    return ArmFinishedUserRoot(physical: physicalRoot, layout: layout)
  }

  @unsafe public init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64,
    layout: ArmPermissionLayout = .direct) {
    guard let root = ArmPrivateRoot(backing: backing, physical: physical, layout: layout) else { return nil }
    self.root = root
  }

  public mutating func insert(virtual: UInt64, physical: UInt64, write: Bool, execute: Bool) -> Bool
  {
    guard virtual < 1 << 47, virtual >= 1 << 32 else { return false }
    let leaf = layout.userLeaf(physical, write: write, execute: execute)
    guard leaf != 0 else { return false }
    return root.insert(
      virtual: virtual, physical: physical,
      leaf: leaf | (execute ? (UInt64(1) << 50) : 0))
  }

  /// Dedicated fresh, pinned normal RAM in a private GCS reservation. No
  /// other writable mapping (ordinary, GCS or DMA) may alias this frame.
  public mutating func insertControlPage(virtual: UInt64, physical: UInt64) -> Bool {
    guard virtual >= 1 << 43, virtual < 1 << 46 else { return false }
    return root.insert(virtual: virtual, physical: physical, leaf: layout.controlLeaf(physical))
  }

  public func mapsControlPage(_ va: UInt64, physical: UInt64) -> Bool {
    va >= 1 << 43 && va < 1 << 46 && va & 16383 == 0 && root.mapsControl(va, physical)
  }

  /// Seal complete RELRO pages in an exclusively held, never-active root.
  /// The caller owns the frames and must exclude writable aliases and DMA.
  /// No TLB invalidation: this is not an active address-space edit.
  public mutating func sealReadOnly(_ range: Range<UInt64>) -> Bool {
    guard root.canSeal(range) else { return false }
    root.sealValidated(range)
    return true
  }

  func entryPage(_ va: UInt64, is role: ArmEntryPage) -> Bool {
    va >= 1 << 32 && va < 1 << 47 && root.hasLeaf(va, role)
  }

  public func mapsPrivateDataPage(_ va: UInt64, physical: UInt64) -> Bool {
    va >= 1 << 32 && va < 1 << 47 && (va | physical) & 16383 == 0
      && root.privateWritableFrame(va) == physical
  }

  /// Install one process-key-signed pointer, then seal the complete RELRO
  /// segment. `frame` is the kernel's exclusive writable mapping of precisely
  /// `physical` (no aliases to the rest of the process, page tables, or DMA).
  /// Hold that frame and this unpublished root exclusively throughout.
  @unsafe public mutating func bindPrivateImport(slot: UInt64, target: UInt64, modifier: UInt64,
    libraryCode: Range<UInt64>, relro: Range<UInt64>, frame: UnsafeMutableRawBufferPointer,
    physical: UInt64, sign: (UInt64, UInt64) -> UInt64?) -> Bool {
    let page: UInt64 = 16384
    guard slot & 7 == 0, target & 3 == 0, libraryCode.contains(target),
      libraryCode.upperBound - target >= 4, libraryCode.lowerBound >= 1 << 32,
      libraryCode.upperBound <= 1 << 43, relro.contains(slot), relro.upperBound - slot >= 8,
      relro.lowerBound >= 1 << 32, relro.upperBound <= 1 << 43,
      !relro.overlaps(libraryCode), (relro.lowerBound | relro.upperBound) & (page-1) == 0,
      modifier & 0x0000_ffff_ffff_ffff == slot, frame.count == Int(page),
      let p = frame.baseAddress, UInt(bitPattern: p) & 7 == 0,
      root.privateWritableFrame(slot) == physical, entryPage(target, is: .code), root.canSeal(relro),
      let signed = sign(target, modifier)
    else { return false }
    let at = Int(slot & (page-1))
    p.storeBytes(of: signed.littleEndian, toByteOffset: at, as: UInt64.self)
    root.sealValidated(relro)
    return true
  }
}

/// A separate upper-half TTBR1 root; all leaves deny EL0, including EL0
/// instruction fetch. Caller pins and owns the arena and all mapped frames.
public struct ArmKernelTranslation: ~Copyable {
  private var root: ArmPrivateRoot
  public var physicalRoot: UInt64 { root.physicalRoot }
  public var usedPages: Int { root.usedPages }
  public var layout: ArmPermissionLayout { root.layout }

  public func mapsPrivateDataPage(_ va: UInt64, physical: UInt64) -> Bool {
    va >= 0xffff_8000_0000_0000 && physical > 0 && physical < 1 << 48
      && (va | physical) & 16383 == 0 && root.mapsKernelData(va, physical: physical)
  }

  func isGuard(_ va: UInt64) -> Bool {
    va >= 0xffff_8000_0000_0000 && root.hasLeaf(va, .guardPage)
  }

  public consuming func finish() -> ArmFinishedKernelRoot? {
    guard usedPages > 1 else { return nil }
    return ArmFinishedKernelRoot(physical: physicalRoot, layout: layout)
  }

  @unsafe public init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64,
    layout: ArmPermissionLayout = .direct) {
    guard let root = ArmPrivateRoot(backing: backing, physical: physical, layout: layout) else { return nil }
    self.root = root
  }

  public mutating func insert(virtual: UInt64, physical: UInt64, write: Bool, execute: Bool) -> Bool
  {
    guard virtual >= 0xffff_8000_0000_0000, physical & 16383 == 0, physical < 1 << 48,
      !(write && execute)
    else { return false }
    let ap: UInt64 = write ? 0 : 0x80
    // Under PIE, PIIndex 10 is privileged R, not executable at either EL.
    let fetch = UInt64(1) << (execute ? 50 : (!write && layout == .guarded ? 51 : 53))
    let leaf = physical | 0x703 | ap | fetch | (1 << 54)
    return root.insert(virtual: virtual, physical: physical, leaf: leaf)
  }

  /// One independently identified read-only MMIO page, never normal RAM.
  /// Pin MAIR[1] = Device-nGnRnE; exclude all writable, cacheable and user aliases.
  public mutating func insertReadOnlyDevice(virtual: UInt64, physical: UInt64) -> Bool {
    guard virtual >= 0xffff_8000_0000_0000, physical & 16383 == 0, physical < 1 << 48
    else { return false }
    // Direct: AP=RO privileged + PXN + UXN. PIE: PIIndex 10 is RO at
    // EL2 and inaccessible at EL0. MAIR index 1, outer shareable, AF.
    let perms: UInt64 = (1 << 54) | (layout == .direct ? 1 << 53 : 1 << 51)
    return root.insert(virtual: virtual, physical: physical, leaf: physical | 0x687 | perms)
  }
}

/// Finished descriptors, not a runnable process or an ASID allocation.
public struct ArmFinishedUserRoot: ~Copyable {
  public let physical: UInt64
  public let layout: ArmPermissionLayout
  fileprivate init(physical: UInt64, layout: ArmPermissionLayout) {
    self.physical = physical; self.layout = layout
  }
}

public struct ArmFinishedKernelRoot: ~Copyable {
  public let physical: UInt64
  public let layout: ArmPermissionLayout
  fileprivate init(physical: UInt64, layout: ArmPermissionLayout) {
    self.physical = physical; self.layout = layout
  }
}
