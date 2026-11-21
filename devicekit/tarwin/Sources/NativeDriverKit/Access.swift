// Driver-side ownership of an already isolated DmaBuffer. Kernel handle
// lifetime and synchronous domain invalidation remain Tarwin's. Never
// substitute virtual/physical addresses for the returned IOVA.
public enum DmaDirection: Equatable {
  case toDevice
  case fromDevice
  case bidirectional
}
public enum BufferOwner: Equatable {
  case cpu
  case device
  case retiring
  case retired
}
public struct DmaSegment: Equatable {
  public let iova: UInt64, bytes: UInt64
}
public struct DmaSegmentLimits {
  public let granularity: UInt64, maximumBytes: UInt64, boundary: UInt64, count: Int
  public init?(granularity: UInt64, maximumBytes: UInt64, boundary: UInt64 = 0, count: Int) {
    guard granularity.nonzeroBitCount == 1, maximumBytes >= granularity,
      (1...65536).contains(count),
      boundary == 0 || boundary.nonzeroBitCount == 1 && boundary >= granularity
    else { return nil }
    self.granularity = granularity
    self.maximumBytes = maximumBytes
    self.boundary = boundary
    self.count = count
  }
}
/// Adopt each kernel grant once. References to it share one ownership state.
/// Access on the driver's serial executor; not Sendable across workers.
public final class NativeDmaBuffer: Equatable {
  public let handle: UInt64
  public let iova: UInt64
  public let length: UInt64
  public let direction: DmaDirection
  public private(set) var owner: BufferOwner = .cpu
  private var transitioning = false

  public static func == (lhs: NativeDmaBuffer, rhs: NativeDmaBuffer) -> Bool { lhs === rhs }

  public func suitable(_ alignment: UInt64, _ boundary: UInt64) -> Bool {
    if handle == 0 || length == 0 || length - 1 > 0xffff_ffff_ffff_ffff - iova || alignment == 0
      || (alignment & (alignment - 1)) != 0 || iova % alignment != 0
    {
      return false
    }
    if boundary == 0 { return true }
    if (boundary & (boundary - 1)) != 0 { return false }
    return length <= boundary - iova % boundary
  }

  public func prepareForDevice(_ syncForDevice: (UInt64, DmaDirection) -> Bool) -> Bool {
    guard !transitioning, owner == .cpu, suitable(1, 0) else { return false }
    transitioning = true
    defer { transitioning = false }
    guard syncForDevice(handle, direction) else { return false }
    owner = .device
    return true
  }
  public func completeFromDevice(_ syncForCpu: (UInt64, DmaDirection) -> Bool) -> Bool {
    guard !transitioning, owner == .device else { return false }
    transitioning = true
    defer { transitioning = false }
    guard syncForCpu(handle, direction) else { return false }
    owner = .cpu
    return true
  }
  /// Offer a complete descriptor list for a subrange of this prepared grant.
  /// On success retain device ownership until the queue confirms completion.
  public func withDeviceSegments(
    offset: UInt64, bytes: UInt64, access: DmaDirection,
    limits: DmaSegmentLimits, publish: (UnsafeBufferPointer<DmaSegment>) -> Bool
  ) -> Bool {
    guard !transitioning, owner == .device, direction == .bidirectional || direction == access,
      bytes > 0, offset < length, bytes <= length - offset
    else { return false }
    var a = iova + offset
    var left = bytes
    let mask = limits.granularity - 1
    guard (a | bytes) & mask == 0 else { return false }
    var segments = [DmaSegment]()
    while left > 0 {
      guard segments.count < limits.count else { return false }
      var n = min(left, limits.maximumBytes & ~mask)
      if limits.boundary != 0 { n = min(n, limits.boundary - (a & (limits.boundary - 1))) }
      segments.append(DmaSegment(iova: a, bytes: n))
      left -= n
      if left > 0 { a += n }
    }
    transitioning = true
    defer { transitioning = false }
    return segments.withUnsafeBufferPointer(publish)
  }
  /// Callback is idempotent for this grant: a partial close or invalidation
  /// can only be retried, never undone by handing it back to the device.
  public func retire(_ closeAndDrain: (UInt64) -> Bool) -> Bool {
    if owner == .retired { return true }
    guard !transitioning, owner == .cpu || owner == .retiring else { return false }
    transitioning = true
    defer { transitioning = false }
    owner = .retiring
    guard closeAndDrain(handle) else { return false }
    owner = .retired
    return true
  }

  public init(handle: UInt64, iova: UInt64, length: UInt64, direction: DmaDirection) {
    self.handle = handle
    self.iova = iova
    self.length = length
    self.direction = direction
  }
}

public func compatibleDriver(
  _ trainYear: UInt32, _ trainMonth: UInt32, _ apiYear: UInt32, _ apiMonth: UInt32
) -> Bool {
  if trainYear > 99 || apiYear > 99 || trainMonth == 0 || trainMonth > 12 || apiMonth == 0
    || apiMonth > 12
  {
    return false
  }
  let train = trainYear * 12 + trainMonth
  let driver = apiYear * 12 + apiMonth
  return driver >= 26 * 12 + 11 && train >= driver && train - driver < 12
}
