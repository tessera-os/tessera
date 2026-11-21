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
  case retired
}
public struct NativeDmaBuffer: Equatable {
  public let handle: UInt64
  public let iova: UInt64
  public let length: UInt64
  public let direction: DmaDirection
  public internal(set) var owner: BufferOwner = .cpu

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

  public mutating func prepareForDevice(_ syncForDevice: (UInt64, DmaDirection) -> Bool) -> Bool {
    if owner != .cpu || !suitable(1, 0) || !syncForDevice(handle, direction) { return false }
    owner = .device
    return true
  }
  public mutating func completeFromDevice(_ syncForCpu: (UInt64, DmaDirection) -> Bool) -> Bool {
    if owner != .device || !syncForCpu(handle, direction) { return false }
    owner = .cpu
    return true
  }
  public mutating func retire(_ closeAndDrain: (UInt64) -> Bool) -> Bool {
    if owner == .retired { return true }
    if owner != .cpu || !closeAndDrain(handle) { return false }
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
