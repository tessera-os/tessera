// PCI 1.3 modern transport. Snapshot the first 256 config bytes through
// DeviceSlot; bars holds lengths of validated MMIO BARs (zero for I/O BARs,
// unavailable BARs, or the upper half of a 64-bit BAR).
public struct PciWindow: Equatable {
  public let bar: UInt8
  public let offset: UInt64
  public let length: UInt64

  public init(bar: UInt8, offset: UInt64, length: UInt64) {
    self.bar = bar
    self.offset = offset
    self.length = length
  }
}
public struct TransportWindows: Equatable {
  public let common: PciWindow
  public let notify: PciWindow
  public let isr: PciWindow
  public let config: PciWindow
  public let multiplier: UInt32

  public init(
    common: PciWindow, notify: PciWindow, isr: PciWindow, config: PciWindow, multiplier: UInt32
  ) {
    self.common = common
    self.notify = notify
    self.isr = isr
    self.config = config
    self.multiplier = multiplier
  }
}
public enum PciDiscovery: Equatable {
  case invalid
  case found(TransportWindows)
}

func configLe(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt32 {
  var value: UInt32 = 0
  for i in 0..<width { value |= UInt32(bytes[at + i]) << UInt32(i * 8) }
  return value
}

public func discoverVirtioPci(_ bytes: [UInt8], _ bars: [UInt64], _ deviceType: UInt16)
  -> PciDiscovery
{
  if bytes.count < 256 || bars.count != 6 || deviceType == 0 || deviceType > 63
    || configLe(bytes, 0, 2) != 0x1af4 || configLe(bytes, 2, 2) != 0x1040 + UInt32(deviceType)
    || (bytes[6] & 16) == 0 || (bytes[14] & 127) != 0
  {
    return .invalid
  }
  let empty = PciWindow(bar: 0, offset: 0, length: 0)
  var regions = [empty, empty, empty, empty]
  var multiplier: UInt32 = 0
  var visited: UInt64 = 0
  var at = Int(bytes[0x34])
  while at != 0 {
    if at < 64 || at > 252 || at % 4 != 0 { return .invalid }
    let mark = UInt64(1) << UInt64(at / 4)
    if (visited & mark) != 0 { return .invalid }
    visited |= mark
    let following = Int(bytes[at + 1])
    if bytes[at] == 9 {
      let length = Int(bytes[at + 2])
      if length < 4 || length > 256 - at { return .invalid }
      let kind = Int(bytes[at + 3])
      if kind >= 1 && kind <= 4 && regions[kind - 1].length == 0 {
        if length < 16 || (kind == 2 && length < 20) { return .invalid }
        let bar = bytes[at + 4]
        let offset = UInt64(configLe(bytes, at + 8, 4))
        let size = UInt64(configLe(bytes, at + 12, 4))
        var minimum: UInt64 = 1
        if kind == 1 { minimum = 56 }
        if kind == 2 { minimum = 2 }
        if bar >= 6 || size < minimum || offset >= bars[Int(bar)] || size > bars[Int(bar)] - offset
        {
          return .invalid
        }
        if (kind == 1 && offset % 4 != 0) || (kind == 2 && offset % 2 != 0) { return .invalid }
        regions[kind - 1] = PciWindow(bar: bar, offset: offset, length: size)
        if kind == 2 {
          multiplier = configLe(bytes, at + 16, 4)
          if multiplier != 0 && (multiplier < 2 || (multiplier & (multiplier - 1)) != 0) {
            return .invalid
          }
        }
      }
    }
    at = following
  }
  if regions[0].length == 0 || regions[1].length == 0 || regions[2].length == 0 { return .invalid }
  return .found(
    TransportWindows(
      common: regions[0], notify: regions[1], isr: regions[2],
      config: regions[3], multiplier: multiplier))
}

// Accessors are relative to common_cfg with ordered little-endian accesses
// of exactly the supplied width, serialized across selector transactions.
public func negotiatePci(
  _ bits: UInt32, _ read: (UInt32, UInt32) -> UInt32, _ write: (UInt32, UInt32, UInt32) -> Void,
  _ resetTimedOut: () -> Bool
) -> MmioFeatures {
  write(20, 1, 0)
  while read(20, 1) != 0 { if resetTimedOut() { return .unavailable } }
  write(20, 1, 1)
  write(20, 1, 3)
  write(0, 4, 0)
  let low = read(4, 4)
  write(0, 4, 1)
  let features = isolatedSplitFeatures((UInt64(read(4, 4)) << 32) | UInt64(low), bits)
  if features == 0 {
    write(20, 1, 0x83)
    return .unavailable
  }
  write(8, 4, 0)
  write(12, 4, UInt32(features & 0xffff_ffff))
  write(8, 4, 1)
  write(12, 4, UInt32(features >> 32))
  write(20, 1, 11)
  if read(20, 1) != 11 {
    write(20, 1, read(20, 1) | 0x80)
    return .unavailable
  }
  return .negotiated(features)
}

public enum QueueNotify: Equatable {
  case invalid
  case offset(UInt64)
}
public func setupPciQueue(
  _ index: UInt16, _ memory: QueueMemory, _ transport: TransportWindows,
  _ read: (UInt32, UInt32) -> UInt32, _ write: (UInt32, UInt32, UInt32) -> Void
) -> QueueNotify {
  if read(20, 1) != 11 || UInt32(index) >= read(18, 2) || !splitMemoryValid(memory) {
    return .invalid
  }
  write(22, 2, UInt32(index))
  if memory.count > read(24, 2) || read(28, 2) != 0 { return .invalid }
  let doorbell = UInt64(read(30, 2)) * UInt64(transport.multiplier)
  if doorbell >= transport.notify.length || transport.notify.length - doorbell < 2 {
    return .invalid
  }
  write(24, 2, memory.count)
  write(32, 4, UInt32(memory.descriptors & 0xffff_ffff))
  write(36, 4, UInt32(memory.descriptors >> 32))
  write(40, 4, UInt32(memory.available & 0xffff_ffff))
  write(44, 4, UInt32(memory.available >> 32))
  write(48, 4, UInt32(memory.used & 0xffff_ffff))
  write(52, 4, UInt32(memory.used >> 32))
  write(28, 2, 1)
  if read(28, 2) != 1 { return .invalid }
  return .offset(transport.notify.offset + doorbell)
}
