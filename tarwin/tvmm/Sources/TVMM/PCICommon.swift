// Virtio 1.3 §4.1.4.3: common configuration BAR of a modern split-ring device.
public struct SplitQueueLayout {
  public var size: UInt16
  public var descriptor: UInt64 = 0
  public var driver: UInt64 = 0
  public var device: UInt64 = 0
  public fileprivate(set) var enabled = false
  public fileprivate(set) var vector: UInt16 = .max

  public init(size: UInt16) { self.size = size }

  public func valid(in ram: GuestAperture, eventIndex: Bool) -> Bool {
    guard size != 0, size <= 32768, size.nonzeroBitCount == 1,
      descriptor % 16 == 0, driver % 2 == 0, device % 4 == 0
    else { return false }
    let n = UInt64(size)
    let event: UInt64 = eventIndex ? 2 : 0
    let spans = [(descriptor, n * 16), (driver, 4 + 2 * n + event), (device, 4 + 8 * n + event)]
    for (i, (base, length)) in spans.enumerated() {
      guard containsSpan(ram, base, length) else { return false }
      for (other, len) in spans.prefix(i) {
        if base >= other ? base - other < len : other - base < length { return false }
      }
    }
    return true
  }
}

public struct PCICommon {
  private let sizes: [UInt16]
  private let vectors: UInt16
  private var devicePage: UInt32 = 0
  private var driverPage: UInt32 = 0
  private var requested: UInt64 = 0
  private var select: UInt16 = 0
  public private(set) var configVector: UInt16 = .max
  public private(set) var generation: UInt8 = 0
  public private(set) var queues: [SplitQueueLayout]
  public private(set) var transport: ModernVirtio

  public init?(features: UInt64, sizes: [UInt16], vectors: UInt16) {
    // Device-specific features, event-index and VERSION_1 only: no indirect
    // descriptors, packed queues, notification data, access platform or ring reset.
    let supported: UInt64 = (1 << 32) | (1 << 29) | ((1 << 24) - 1)
    guard features & (1 << 32) != 0, features & ~supported == 0, vectors <= 2048,
      !sizes.isEmpty, sizes.count <= Int(UInt16.max),
      sizes.allSatisfy({ $0.nonzeroBitCount == 1 && $0 <= 32768 })
    else { return nil }
    self.sizes = sizes
    self.vectors = vectors
    queues = sizes.map(SplitQueueLayout.init)
    transport = ModernVirtio(offered: features)
  }

  public mutating func deviceConfigChanged() { generation &+= 1 }

  public func read(offset: Int, width: Int) -> UInt64? {
    let q = Int(select) < queues.count ? queues[Int(select)] : nil
    switch (offset, width) {
    case (0, 4): return UInt64(devicePage)
    case (4, 4): return devicePage < 2 ? transport.offered >> (devicePage * 32) & 0xffff_ffff : 0
    case (8, 4): return UInt64(driverPage)
    case (12, 4): return driverPage < 2 ? requested >> (driverPage * 32) & 0xffff_ffff : 0
    case (16, 2): return UInt64(configVector)
    case (18, 2): return UInt64(queues.count)
    case (20, 1): return transport.status
    case (21, 1): return UInt64(generation)
    case (22, 2): return UInt64(select)
    case (24, 2): return UInt64(q?.size ?? 0)
    case (26, 2): return UInt64(q?.vector ?? .max)
    case (28, 2): return q?.enabled == true ? 1 : 0
    case (30, 2): return q == nil ? 0 : UInt64(select)
    default:
      guard (32..<56).contains(offset), let q else { return nil }
      let base = (offset - 32) / 8
      let addr = [q.descriptor, q.driver, q.device][base]
      if width == 8 && offset % 8 == 0 { return addr }
      if width == 4 && offset % 4 == 0 { return addr >> ((offset % 8) * 8) & 0xffff_ffff }
      return nil
    }
  }

  // Caller serializes config access. pin must acquire all three ring ranges
  // in this VM atomically; reset drains I/O and releases all pins before reuse.
  public mutating func write(
    offset: Int, width: Int, value: UInt64, ram: GuestAperture,
    pin: (Int, SplitQueueLayout) -> Bool, reset: () -> Bool
  ) -> Bool {
    guard [1, 2, 4, 8].contains(width), width == 8 || value >> (width * 8) == 0 else {
      return false
    }
    let idx = Int(select)
    switch (offset, width) {
    case (0, 4): devicePage = UInt32(value)
    case (8, 4): driverPage = UInt32(value)
    case (12, 4):
      guard transport.status == 3 else { return false }
      guard driverPage < 2 else { return value == 0 }
      let shift = Int(driverPage) * 32
      requested = (requested & ~(UInt64(0xffff_ffff) << shift)) | (value << shift)
    case (16, 2): configVector = value < vectors ? UInt16(value) : .max
    case (20, 1):
      if transport.status == 3 && value & 8 != 0 && !transport.negotiate(requested) { return false }
      guard transport.writeStatus(value, reset) else { return false }
      if value == 0 {
        requested = 0
        select = 0
        configVector = .max
        driverPage = 0
        devicePage = 0
        queues = sizes.map(SplitQueueLayout.init)
      }
    case (22, 2): select = UInt16(value)
    default:
      guard idx < queues.count, transport.status & 8 != 0, transport.status & 128 == 0 else {
        return false
      }
      if (offset, width) == (26, 2) {
        queues[idx].vector = value < vectors ? UInt16(value) : .max
        return true
      }
      guard !queues[idx].enabled else { return false }
      switch (offset, width) {
      case (24, 2):
        guard value > 0, value.nonzeroBitCount == 1, value <= sizes[idx] else { return false }
        queues[idx].size = UInt16(value)
      case (28, 2):
        let q = queues[idx]
        guard value == 1, q.valid(in: ram, eventIndex: requested & (1 << 29) != 0), pin(idx, q)
        else { return false }
        queues[idx].enabled = true
      default:
        guard (32..<56).contains(offset) else { return false }
        let base = (offset - 32) / 8
        var addr = [queues[idx].descriptor, queues[idx].driver, queues[idx].device][base]
        if width == 8 && offset % 8 == 0 {
          addr = value
        } else if width == 4 && offset % 4 == 0 {
          let shift = (offset % 8) * 8
          addr = (addr & ~(UInt64(0xffff_ffff) << shift)) | (value << shift)
        } else {
          return false
        }
        switch base {
        case 0: queues[idx].descriptor = addr
        case 1: queues[idx].driver = addr
        default: queues[idx].device = addr
        }
      }
    }
    return true
  }

  public func notify(slot: UInt16, queue: UInt16, service: (Int, SplitQueueLayout) -> Bool) -> Bool
  {
    let idx = Int(queue)
    guard transport.ready(), slot == queue, idx < queues.count, queues[idx].enabled else {
      return false
    }
    return service(idx, queues[idx])
  }
}
