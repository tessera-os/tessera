import Synchronization
import TarwinABI
import TarwinArchAarch64
import TarwinChannelCalls
import TarwinObject

/// Scoped pins for the first thread's resident, private, untagged stack.
/// No demand paging or COW: other mappings are refused before dequeue.
public struct W1StackOutputPins: ~Copyable {
  fileprivate let child: ProcessKey
  fileprivate let processRoot, hostRoot: UInt64
  fileprivate let stack: Range<UInt64>
  fileprivate let alias: UnsafeMutableRawBufferPointer
  private let pins = Atomic<UInt32>(0)
  private static let closed: UInt32 = 1 << 31

  /// Create a single registry record per stack under exclusive VM ownership.
  /// Verify the same contiguous physical
  /// pages in both direct-permission roots. Keep the frames resident and
  /// private (no DMA), the alias writable/nonfaulting, and both roots and
  /// this record pinned. Revoke and drain before *any* change/COW/retag.
  @unsafe public init?(
    images: borrowing W1PrivateImages, child: borrowing ProcessExecution,
    host: borrowing ArmKernelTranslation, alias: UnsafeMutableRawBufferPointer
  ) {
    self.init(
      images: images, child: child, hostRoot: host.physicalRoot, alias: alias,
      hostPage: { host.mapsPrivateDataPage($0, physical: $1) })
  }

  init?(
    images: borrowing W1PrivateImages, child: borrowing ProcessExecution, hostRoot: UInt64,
    alias: UnsafeMutableRawBufferPointer, hostPage: (UInt64, UInt64) -> Bool
  ) {
    guard let t = images.initialThread, child.initialMap == images.tables.physicalRoot,
      hostRoot != 0, hostRoot != images.tables.physicalRoot, let p = alias.baseAddress,
      UInt64(alias.count) == t.stack.upperBound - t.stack.lowerBound
    else { return nil }
    let addr = UInt64(UInt(bitPattern: p))
    guard addr & 16383 == 0, UInt64(alias.count) <= UInt64.max - addr else { return nil }
    for i in stride(from: 0, to: alias.count, by: 16384) {
      let pa = t.stackPhysical + UInt64(i)
      guard images.tables.mapsPrivateDataPage(t.stack.lowerBound + UInt64(i), physical: pa),
        hostPage(addr + UInt64(i), pa)
      else { return nil }
    }
    self.child = child.member
    self.processRoot = images.tables.physicalRoot
    self.hostRoot = hostRoot
    self.stack = t.stack
    self.alias = alias
  }

  /// Latch refusal of all new reads. False means a callback is in flight:
  /// defer unmapping and call again. The registry/reader epoch must also
  /// drain before freeing the pin record itself.
  public func revoke() -> Bool {
    pins.bitwiseOr(Self.closed, ordering: .acquiringAndReleasing).newValue == Self.closed
  }

  fileprivate func acquire() -> Bool {
    pins.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged
  }
  fileprivate func release() { _ = pins.wrappingSubtract(1, ordering: .releasing) }
}

/// Obtain from the trusted current task/root under its dispatch epoch.
/// This view does not keep the pin registry alive. Never cache it across
/// a root switch or the end of the caller's epoch.
public struct W1StackChannelOutput: ChannelUserOutput {
  private let record: UnsafePointer<W1StackOutputPins>
  public var userRange: Range<UInt64> { record.pointee.stack }

  @unsafe public init?(
    pins: UnsafePointer<W1StackOutputPins>, child: borrowing ProcessExecution,
    activeUserRoot: UInt64, activeHostRoot: UInt64
  ) {
    guard child.member == pins.pointee.child, child.initialMap == activeUserRoot,
      activeUserRoot == pins.pointee.processRoot, activeHostRoot == pins.pointee.hostRoot
    else { return nil }
    record = pins
  }

  public mutating func withWritable(
    bytes: Range<UInt64>, names: Range<UInt64>,
    _ body: (UnsafeMutableRawBufferPointer, UnsafeMutableBufferPointer<UInt64>) -> CallResult
  ) -> CallResult? {
    func offsets(_ r: Range<UInt64>, limit: UInt64) -> Range<Int>? {
      if r.isEmpty { return r.lowerBound == 0 ? 0..<0 : nil }
      let s = record.pointee.stack
      guard s.contains(r.lowerBound), r.upperBound <= s.upperBound,
        r.upperBound - r.lowerBound <= limit
      else { return nil }
      return Int(r.lowerBound - s.lowerBound)..<Int(r.upperBound - s.lowerBound)
    }
    guard (names.lowerBound | names.upperBound) & 7 == 0,
      let b = offsets(bytes, limit: 65536), let h = offsets(names, limit: 512),
      !b.overlaps(h), record.pointee.acquire()
    else { return nil }
    defer { record.pointee.release() }
    // The two checked maps are one-to-one over this run, so disjoint
    // offsets are disjoint physical bytes, including on the same page.
    let a = record.pointee.alias
    let words = UnsafeMutableRawBufferPointer(rebasing: a[h])
    return body(.init(rebasing: a[b]), words.bindMemory(to: UInt64.self))
  }
}
