// §28.1. The logger names this ring's subsystem "tessera.kernel".
// Filter before timestamp sampling, evaluating message content, or taking a slot.
public enum KernelLogLevel: UInt8 { case trace, debug, info, notice, warning, error, fault }

public struct KernelLogFilter {
  private var minimum: InlineArray<17, UInt8>
  public init(defaultLevel: KernelLogLevel?) {
    minimum = .init(repeating: defaultLevel?.rawValue ?? .max)
  }
  public mutating func set(_ category: KernelCategory, minimum level: KernelLogLevel?) {
    minimum[Int(category.rawValue)] = level?.rawValue ?? .max
  }
  public func records(_ category: KernelCategory, _ level: KernelLogLevel) -> Bool {
    level.rawValue >= minimum[Int(category.rawValue)]
  }
}

public struct KernelLogEntry {
  public let monotonicNanos: UInt64
  public let category: KernelCategory
  public let level: KernelLogLevel
  public let length: UInt16
  public let truncated: Bool
  public fileprivate(set) var bytes: InlineArray<256, UInt8> = .init(repeating: 0)
}

public enum LogResult { case filtered, full, stored }
public struct KernelLogProducer {
  private var cursor: RingCursor
  public var dropped: UInt64 { cursor.dropped }
  public init(capacity: UInt64) { cursor = RingCursor(capacity: capacity) }

  public mutating func record(
    _ category: KernelCategory, _ level: KernelLogLevel, filter: borrowing KernelLogFilter,
    monotonic: () -> UInt64, length: UInt64, readByte: (UInt16) -> UInt8, tail: () -> UInt64,
    write: (UInt64, borrowing KernelLogEntry) -> Void, publish: (UInt64) -> Void
  ) -> LogResult {
    guard filter.records(category, level) else { return .filtered }
    guard let slot = cursor.reserve(tail()) else { return .full }
    let count = UInt16(min(256, length))
    var entry = KernelLogEntry(
      monotonicNanos: monotonic(), category: category, level: level,
      length: count, truncated: length > 256)
    for i in 0..<count { entry.bytes[Int(i)] = readByte(i) }
    write(slot, entry)
    cursor.commit(publish)
    return .stored
  }
}
