import TarwinArchAarch64

/// Unpublished EL2 resources for the fixed Arm cold intake. The root has
/// no kernel text, vectors or direct map yet. Do not activate it.
struct W1ColdHostPages: ~Copyable {
  static let page = 16384
  static let tableBytes = 32 * page
  static let bytes = tableBytes + 5 * page
  var tables: ArmKernelTranslation
  let stacks: ArmStopStacks
  let clock: W1ClockReservation

  // A private upper-half window for the first CPU. Eight aligned pages
  // per slot so the masked draw is uniform without rejection or division.
  static func controlBase(draw: UInt64) -> UInt64 {
    0xffff_a000_0000_0000 | ((draw & 0x7f_ffff) << 17)
  }

  /// Backing is the exclusive mapping of this physical tail of the cold
  /// allocation. Keep both roots inactive and every requester denied.
  @unsafe init?(backing: UnsafeMutableRawBufferPointer, physical: UInt64,
    privateAllocation: Range<UInt64>, draw: UInt64) {
    let size = UInt64(Self.bytes), page = UInt64(Self.page)
    guard backing.count == Self.bytes, physical != 0, physical & (page - 1) == 0,
      physical <= (1 << 48) - size, !privateAllocation.isEmpty,
      privateAllocation.upperBound == physical,
      let p = backing.baseAddress, UInt(bitPattern: p) & 7 == 0 else { return nil }
    let stackPA = physical + UInt64(Self.tableBytes)
    let base = Self.controlBase(draw: draw)
    guard var host = ArmKernelTranslation(backing: .init(rebasing: backing[..<Self.tableBytes]),
      physical: physical, layout: .guarded) else { return nil }
    for i: UInt64 in 0..<4 {
      let pageVA = base + (i < 2 ? i + 1 : i + 2) * page
      guard host.insert(virtual: pageVA, physical: stackPA + i * page,
        write: true, execute: false) else { return nil }
    }
    guard let stacks = ArmStopStacks(tables: host,
      outgoingVA: base + page, outgoingPA: stackPA,
      schedulerVA: base + 4 * page, schedulerPA: stackPA + 2 * page),
      let clock = W1ClockReservation(physical: stackPA + 4 * page, kernelVA: base + 6 * page,
        host: &host) else { return nil }
    backing[Self.tableBytes...].initializeMemory(as: UInt8.self, repeating: 0)
    self.tables = consume host
    self.stacks = stacks
    self.clock = consume clock
  }
}
