// Virtio 1.2 modern MMIO transport. DeviceKit supplies ordered I/O register
// accesses and IOVAs already mapped into this device's isolated DMA domain.
public struct QueueMemory: Equatable {
  public let count: UInt32
  public let descriptors: UInt64
  public let available: UInt64
  public let used: UInt64

  public init(count: UInt32, descriptors: UInt64, available: UInt64, used: UInt64) {
    self.count = count
    self.descriptors = descriptors
    self.available = available
    self.used = used
  }
}

func validArea(_ addr: UInt64, _ bytes: UInt64, _ alignment: UInt64) -> Bool {
  return addr % alignment == 0 && bytes > 0 && bytes - 1 <= 0xffff_ffff_ffff_ffff - addr
}

public enum MmioFeatures: Equatable {
  case unavailable
  case negotiated(UInt64)
}
public func negotiateMmio(
  _ deviceId: UInt32, _ deviceBits: UInt32, _ read: (UInt32) -> UInt32,
  _ write: (UInt32, UInt32) -> Void, _ resetTimedOut: () -> Bool
) -> MmioFeatures {
  if deviceId == 0 || read(0) != 0x7472_6976 || read(4) != 2 || read(8) != deviceId {
    return .unavailable
  }
  write(0x70, 0)
  while read(0x70) != 0 { if resetTimedOut() { return .unavailable } }
  write(0x70, 1)
  write(0x70, 3)
  write(0x14, 0)
  let low = read(0x10)
  write(0x14, 1)
  let high = read(0x10)
  let features = isolatedSplitFeatures((UInt64(high) << 32) | UInt64(low), deviceBits)
  if features == 0 {
    write(0x70, 0x83)
    return .unavailable
  }
  write(0x24, 0)
  write(0x20, UInt32(features & 0xffff_ffff))
  write(0x24, 1)
  write(0x20, UInt32(features >> 32))
  write(0x70, 11)
  if read(0x70) != 11 {
    write(0x70, read(0x70) | 0x80)
    return .unavailable
  }
  return .negotiated(features)
}

func addressPair(_ reg: UInt32, _ addr: UInt64, _ write: (UInt32, UInt32) -> Void) {
  write(reg, UInt32(addr & 0xffff_ffff))
  write(reg + 4, UInt32(addr >> 32))
}

func distinctAreas(_ a: UInt64, _ aBytes: UInt64, _ b: UInt64, _ bBytes: UInt64) -> Bool {
  if a <= b { return b - a >= aBytes }
  return a - b >= bBytes
}

func splitMemoryValid(_ memory: QueueMemory) -> Bool {
  let count = UInt64(memory.count)
  if count < 1 || count > 32768 || (count & (count - 1)) != 0 { return false }
  let d = count * 16
  let a = 6 + count * 2
  let u = 6 + count * 8
  if !validArea(memory.descriptors, d, 16) || !validArea(memory.available, a, 2)
    || !validArea(memory.used, u, 4) || !distinctAreas(memory.descriptors, d, memory.available, a)
    || !distinctAreas(memory.descriptors, d, memory.used, u)
    || !distinctAreas(memory.available, a, memory.used, u)
  {
    return false
  }
  return true
}

public func installSplitQueue(
  _ index: UInt32, _ memory: QueueMemory, _ read: (UInt32) -> UInt32,
  _ write: (UInt32, UInt32) -> Void
) -> Bool {
  if !splitMemoryValid(memory) || read(0x70) != 11 { return false }
  write(0x30, index)
  if read(0x44) != 0 || read(0x34) < memory.count { return false }
  write(0x38, memory.count)
  addressPair(0x80, memory.descriptors, write)
  addressPair(0x90, memory.available, write)
  addressPair(0xa0, memory.used, write)
  write(0x44, 1)
  return read(0x44) == 1
}

public func driverReady(_ read: (UInt32) -> UInt32, _ write: (UInt32, UInt32) -> Void) -> Bool {
  if read(0x70) != 11 { return false }
  write(0x70, 15)
  return read(0x70) == 15
}
