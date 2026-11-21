import Synchronization

public struct InputReportRecord {
  public var deviceId: UInt32 = 0
  public var reportLength: UInt16 = 0
  public var timestampNs: UInt64 = 0
  public var bytes: InlineArray<64, UInt8> = .init(repeating: 0)
  public init() {}
}

public final class InputRing: @unchecked Sendable {
  private let slots: UnsafeMutablePointer<InputReportRecord>
  public let capacity: Int
  private let writeIndex = Atomic<UInt64>(0)
  private let readIndex = Atomic<UInt64>(0)
  private let dropped = Atomic<UInt64>(0)
  public var overruns: UInt64 { dropped.load(ordering: .relaxed) }
  public init?(capacity: Int) {
    guard capacity > 0, capacity & (capacity - 1) == 0 else { return nil }
    self.capacity = capacity
    slots = .allocate(capacity: capacity)
    slots.initialize(repeating: InputReportRecord(), count: capacity)
  }
  deinit { slots.deinitialize(count: capacity); slots.deallocate() }
  @discardableResult public func push(_ report: InputReportRecord) -> Bool {
    guard report.reportLength <= 64 else { return false }
    let w = writeIndex.load(ordering: .relaxed)
    guard w &- readIndex.load(ordering: .acquiring) < UInt64(capacity) else {
      dropped.wrappingAdd(1, ordering: .relaxed); return false
    }
    slots[Int(w % UInt64(capacity))] = report
    writeIndex.store(w &+ 1, ordering: .releasing); return true
  }
  public func pop() -> InputReportRecord? {
    let r = readIndex.load(ordering: .relaxed)
    guard r != writeIndex.load(ordering: .acquiring) else { return nil }
    let report = slots[Int(r % UInt64(capacity))]
    readIndex.store(r &+ 1, ordering: .releasing); return report
  }
}
