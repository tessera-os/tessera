import TarwinArchAarch64

/// One fresh, pinned kernel-only frame for the first architectural register
/// bank. The caller excludes DMA, other writers and all process mappings.
/// Do not reuse until the captured thread has stopped on a different stack.
public struct W1TrapFrameReservation: ~Copyable {
  let root, virtual, physical: UInt64

  @unsafe public init?(virtual: UInt64, physical: UInt64, in host: inout ArmKernelTranslation) {
    guard host.layout == .guarded,
      host.insert(virtual: virtual, physical: physical, write: true, execute: false)
    else { return nil }
    self.root = host.physicalRoot
    self.virtual = virtual
    self.physical = physical
  }

  func matches(root: UInt64, pool: Range<UInt64>, clock: UInt64) -> Bool {
    self.root == root && !pool.isEmpty && physical != clock &&
      !pool.overlaps(physical..<physical + 16384)
  }

  /// Keep the verified host root active and pinned through the last capture.
  /// A valid descriptor in an unpublished root is not a writable pointer.
  @unsafe consuming func open(in host: borrowing ArmFinishedKernelRoot,
    pool: Range<UInt64>, clock: UInt64) -> UnsafeMutableRawBufferPointer? {
    guard host.layout == .guarded, matches(root: host.physical, pool: pool, clock: clock),
      host.permitsLocalWrite(virtual: virtual, physical: physical),
      let p = UnsafeMutableRawPointer(bitPattern: UInt(virtual)) else { return nil }
    return .init(start: p, count: ArmTrapLayout.size)
  }
}
