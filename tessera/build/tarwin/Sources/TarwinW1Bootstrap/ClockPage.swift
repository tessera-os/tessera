import TarwinArchAarch64
import TarwinTime

/// A single dedicated pinned frame of coherent normal RAM. Keep the host
/// root and frame owned until the last process mapping and CPU have retired.
/// The allocator must exclude DMA, device frames and other writable aliases.
public struct W1ClockReservation: ~Copyable {
  let physical, kernelVA: UInt64
  private let hostTables: Range<UInt64>
  var hostRoot: UInt64 { hostTables.lowerBound }
  let layout: ArmPermissionLayout

  public init?(physical: UInt64, kernelVA: UInt64, host: inout ArmKernelTranslation) {
    guard host.insert(virtual: kernelVA, physical: physical, write: true, execute: false) else {
      return nil
    }
    self.physical = physical
    self.kernelVA = kernelVA
    hostTables = host.tableReservation
    layout = host.layout
  }

  /// Check before the user table builder zeroes any of the proposed RAM.
  func permitsPrivateStorage(_ pool: Range<UInt64>) -> Bool {
    !pool.isEmpty && !pool.overlaps(hostTables) && !pool.overlaps(physical..<physical + 16384)
  }

  func install(in tables: inout ArmUserTranslation, privatePool: Range<UInt64>) -> Bool {
    guard tables.physicalRoot == privatePool.lowerBound, tables.layout == layout,
      permitsPrivateStorage(privatePool) else { return false }
    return tables.insert(virtual: TimePageReader.address47, physical: physical, write: false, execute: false)
  }

  /// Only under the matching active, pinned host root. Never publish
  /// through a temporary boot identity mapping which may later disappear.
  @unsafe public consuming func start(
    in host: borrowing ArmFinishedKernelRoot, clock: SystemClocks
  ) -> W1ClockPage? {
    guard host.physical == hostRoot, host.layout == layout,
      host.permitsLocalWrite(virtual: kernelVA, physical: physical),
      let p = UnsafeMutableRawPointer(bitPattern: UInt(kernelVA)) else { return nil }
    return startMapped(in: host, clock: clock, bytes: .init(start: p, count: 16384))
  }

  consuming func startMapped(
    in host: borrowing ArmFinishedKernelRoot, clock: SystemClocks, bytes: UnsafeMutableRawBufferPointer
  ) -> W1ClockPage? {
    guard host.physical == hostRoot, host.layout == layout, bytes.count == 16384,
      let clocks = PublishedClocks(freshPage: bytes, clock: clock) else { return nil }
    return W1ClockPage(mapping: consume self, clocks: consume clocks)
  }
}

/// Serialized single publisher; a process gets only the read-only leaf.
public struct W1ClockPage: ~Copyable {
  let mapping: W1ClockReservation
  fileprivate var clocks: PublishedClocks
  public var snapshot: SystemClocks? { clocks.snapshot }
  public mutating func update(_ change: ClockUpdate, counter: UInt64) -> Bool {
    clocks.update(change, counter: counter)
  }
}
