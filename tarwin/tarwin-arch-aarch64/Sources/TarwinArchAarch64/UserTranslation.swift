/// Builds an unpublished lower-half, 48-bit VA, 16 KiB stage-1 root in
/// private, contiguous table pages. The owner pins the backing and must not
/// alias, publish or activate the root while this builder is being used.
/// No blocks, LPA2, kernel aliases, replacement or live PTE edits.
public struct ArmUserTranslation: ~Copyable {
  private let words: UnsafeMutableBufferPointer<UInt64>
  public let physicalRoot: UInt64
  public private(set) var usedPages: Int

  @unsafe public init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64) {
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

  /// Caller establishes memory-object rights, lifetime and exclusivity of the
  /// frame (including writable aliases elsewhere) before requesting a leaf.
  public mutating func insert(virtual: UInt64, physical: UInt64, write: Bool, execute: Bool) -> Bool
  {
    guard virtual < 1 << 47, virtual >= 1 << 32, virtual & 16383 == 0, physical != 0,
      physical < physicalRoot || physical >= physicalRoot + UInt64(words.count) * 8
    else { return false }
    let leaf = armUserPage(physical, write: write, execute: execute, lpa2: false)
    guard leaf != 0 else { return false }
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
    // All executable pages in this regime are BTI guarded and EL1-XN.
    words[entry] = leaf | (execute ? (UInt64(1) << 50) : 0)
    return true
  }
}
