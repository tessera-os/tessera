/// Sorted image reservations of one process. The caller owns the initialized
/// kernel storage and holds exclusive map access from selection through commit.
/// A reservation excludes other placements; it neither installs nor grants pages.
public struct ImageReservations: ~Copyable {
  private let slots: UnsafeMutableBufferPointer<Range<UInt64>>
  public let pageSize: UInt64
  private let userBits: UInt8
  public private(set) var count: Int

  public init?(
    storage: UnsafeMutableBufferPointer<Range<UInt64>>, used: Int,
    pageSize: UInt64, userBits: UInt8
  ) {
    guard used >= 0, used <= storage.count,
      pageSize == 4096 || pageSize == 16384, userBits == 47 || userBits == 56
    else { return nil }
    var end: UInt64 = 0
    for i in 0..<used {
      let span = storage[i]
      guard span.lowerBound >= end, Self.valid(span, pageSize, userBits) else { return nil }
      end = span.upperBound
    }
    self.slots = storage
    self.count = used
    self.pageSize = pageSize
    self.userBits = userBits
  }

  /// Borrow only until the next mutation, under the same exclusive ownership.
  public var occupied: UnsafeBufferPointer<Range<UInt64>> {
    UnsafeBufferPointer(start: slots.baseAddress, count: count)
  }

  private static func valid(_ span: Range<UInt64>, _ pageSize: UInt64, _ userBits: UInt8) -> Bool {
    span.lowerBound < span.upperBound
      && userRegion(span.lowerBound, length: span.upperBound - span.lowerBound,
        pageSize: pageSize, userBits: userBits) == 1
  }

  /// Commit both chosen, page-rounded extents or leave all storage untouched.
  public mutating func reservePair(_ process: Range<UInt64>, _ library: Range<UInt64>) -> Bool {
    guard slots.count - count >= 2, Self.valid(process, pageSize, userBits),
      Self.valid(library, pageSize, userBits), !process.overlaps(library)
    else { return false }
    for i in 0..<count {
      guard !slots[i].overlaps(process), !slots[i].overlaps(library) else { return false }
    }
    insert(process)
    insert(library)
    return true
  }

  private mutating func insert(_ span: Range<UInt64>) {
    var i = count
    while i > 0 && slots[i - 1].lowerBound > span.lowerBound {
      slots[i] = slots[i - 1]
      i -= 1
    }
    slots[i] = span
    count += 1
  }
}
