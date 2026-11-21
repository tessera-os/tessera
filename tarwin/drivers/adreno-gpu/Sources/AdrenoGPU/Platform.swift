import TarwinDevice

public enum AdrenoCacheMode: Sendable { case cached, uncached, writeCombined }

/// A Memory object owned by the provider's process, with its persistent local mapping.
public struct AdrenoMemory: @unchecked Sendable {
  public let koid: UInt64
  public let bytes: UInt64
  public let cpuAddress: UnsafeMutableRawPointer

  public init(koid: UInt64, bytes: UInt64, cpuAddress: UnsafeMutableRawPointer) {
    self.koid = koid
    self.bytes = bytes
    self.cpuAddress = cpuAddress
  }
}

public enum AdrenoIrqWait: Sendable { case raised, timedOut, cancelled, disconnected }

/// Trusted composition for one admitted GPU slot. Register access goes through
/// `mapSlotRegisters`; DMA follows `DmaRetirement` (#4515): every step is
/// synchronous, a failed step is retried later and never skipped, and a pin is
/// released only after detach, IOTLB and ATC invalidation and write drain.
public protocol AdrenoPlatform: AnyObject, Sendable {
  func mapRegisters(_ registers: DeviceRange) -> Bool
  func read32(_ register: UInt32) -> UInt32
  func write32(_ register: UInt32, _ value: UInt32)

  func createMemory(bytes: UInt64, cache: AdrenoCacheMode) -> AdrenoMemory?
  /// GPU footprint charge; refunded only after the memory's DMA is released.
  func charge(_ memory: UInt64, bytes: UInt64) -> Bool
  func refund(_ memory: UInt64, bytes: UInt64)
  func closeMemory(_ memory: UInt64)

  func randomWord() -> UInt64
  /// Returns 0 on failure.
  func pin(_ memory: UInt64, _ span: DmaSpan) -> UInt64
  func mapPinned(_ domain: UInt64, _ iova: UInt64, _ pin: UInt64, _ span: DmaSpan) -> Bool
  func detach(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool
  func invalidateIo(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool
  func invalidateAtcs(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool
  func drainWrites(_ domain: UInt64, _ iova: UInt64, _ bytes: UInt64) -> Bool
  func releasePin(_ pin: UInt64) -> Bool

  /// Blocks until the GPU interrupt is delivered (acknowledged and masked by
  /// the kernel) or the wait ends. `completeInterrupt` rearms and unmasks it.
  func waitInterrupt(timeoutNanoseconds: UInt64) -> AdrenoIrqWait
  func completeInterrupt()
}
