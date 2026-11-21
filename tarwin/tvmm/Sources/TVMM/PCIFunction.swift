// One serialized function per sandboxed VM. The backend retains ring pins until
// reset and must quiesce DMA before returning from a bus-master disable.
public protocol VirtioPCIBackend: AnyObject {
  var ram: GuestAperture { get }
  func pin(queue: Int, layout: SplitQueueLayout) -> Bool
  func reset() -> Bool
  func setBusMaster(_ enabled: Bool) -> Bool
  func kick(queue: Int, layout: SplitQueueLayout) -> Bool
  func readConfig(offset: Int, width: Int) -> UInt64?
  func writeConfig(offset: Int, width: Int, value: UInt64) -> Bool
  func inject(message: UInt64, data: UInt32) -> Bool
  func setINTx(asserted: Bool)
}

private func mask(_ width: Int) -> UInt64 { .max >> (64 - width * 8) }

public final class VirtioPCIFunction {
  public private(set) var common: PCICommon
  let barSize: UInt32
  private(set) var base: UInt32 = 0
  private var command: UInt16 = 0
  var decodes: Bool { command & 2 != 0 }
  private var master: Bool { command & 4 != 0 }
  private var isr: UInt8 = 0
  private var config = [UInt8](repeating: 0, count: 256)
  private var msix: GuestMSIX
  private let backend: any VirtioPCIBackend
  private let configLength, notifyLength, table, pending: Int

  public init?(
    device: UInt16, classCode: UInt32, features: UInt64, queues: [UInt16],
    vectors: UInt16, configLength: Int, backend: any VirtioPCIBackend
  ) {
    guard (1...63).contains(device), classCode <= 0xffffff, (0...3840).contains(configLength),
      let common = PCICommon(features: features, sizes: queues, vectors: vectors),
      let msix = GuestMSIX(count: Int(vectors))
    else { return nil }
    self.common = common
    self.msix = msix
    self.backend = backend
    self.configLength = configLength
    notifyLength = queues.count * 4
    table = (4096 + notifyLength + 4095) & ~4095
    pending = table + msix.count * 16
    var size: UInt32 = 4096
    while size < pending + (msix.count + 63) / 64 * 8 { size *= 2 }
    barSize = size
    let id = UInt32(0x1040) + UInt32(device)
    put(0, 4, id << 16 | 0x1af4)
    put(6, 2, 16)  // capabilities list
    put(8, 4, classCode << 8 | 1)
    put(0x2c, 4, id << 16 | 0x1af4)
    config[0x34] = 0x40
    config[0x3d] = 1
    capability(0x40, next: 0x50, kind: 1, offset: 0, length: 56)
    capability(0x50, next: 0x64, kind: 2, offset: 4096, length: notifyLength)
    put(0x60, 4, 4)
    capability(0x64, next: configLength > 0 ? 0x74 : 0x84, kind: 3, offset: 64, length: 1)
    if configLength > 0 { capability(0x74, next: 0x84, kind: 4, offset: 256, length: configLength) }
    capability(0x84, next: 0x98, kind: 5, offset: 0, length: 0)
    put(0x98, 4, UInt32(msix.count - 1) << 16 | 0xa411)
    put(0x9c, 4, UInt32(table))
    put(0xa0, 4, UInt32(pending))
    put(0xa4, 4, 0x0080_0005)  // 64-bit, single-message MSI
  }

  private func put(_ at: Int, _ width: Int, _ value: UInt32) {
    for i in 0..<width { config[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
  }
  private func capability(_ at: Int, next: UInt8, kind: UInt8, offset: Int, length: Int) {
    config[at] = 9
    config[at + 1] = next
    config[at + 2] = kind == 2 || kind == 5 ? 20 : 16
    config[at + 3] = kind
    put(at + 8, 4, UInt32(offset))
    put(at + 12, 4, UInt32(length))
  }

  private var msi: Bool { config[0xa6] & 1 != 0 }
  private func updateLine() {
    backend.setINTx(asserted: !msix.enabled && !msi && command & 0x400 == 0 && isr != 0)
  }
  private func signal(_ vector: UInt16, bit: UInt8) -> Bool {
    if msix.enabled {
      guard vector != .max else { return true }  // driver explicitly unmapped this event
      return msix.signal(Int(vector), inject: inject)
    }
    isr |= bit
    if msi { return inject(vword(config, 0xa8, 8), UInt32(vword(config, 0xb0, 2))) }
    updateLine()
    return true
  }
  private func inject(_ message: UInt64, _ data: UInt32) -> Bool {
    master && backend.inject(message: message, data: data)
  }
  public func queueInterrupt(_ queue: Int) -> Bool {
    guard common.transport.ready(), common.queues.indices.contains(queue),
      common.queues[queue].enabled
    else { return false }
    return signal(common.queues[queue].vector, bit: 1)
  }
  public func configChanged() -> Bool {
    common.deviceConfigChanged()
    return !common.transport.ready() || signal(common.configVector, bit: 2)
  }
  private func indirect(_ width: Int) -> Int? {
    let offset = Int(vword(config, 0x8c, 4))
    guard config[0x88] == 0, vword(config, 0x90, 4) == UInt64(width),
      offset % width == 0, offset + width <= table
    else { return nil }
    return offset
  }
  func configRead(_ offset: Int, _ width: Int) -> UInt64? {
    if offset == 0x94 {
      guard let at = indirect(width) else { return nil }
      return read(at, width)
    }
    guard offset < 256 else { return 0 }
    return vword(config, offset, width)
  }

  func configWrite(_ offset: Int, _ width: Int, _ value: UInt64) -> Bool {
    if offset == 0x94 {
      guard let at = indirect(width) else { return false }
      return write(at, width, value)
    }
    guard offset < 256 else { return true }
    var nextCommand = UInt32(command)
    var nextBase = base
    var ctrl = UInt32(vword(config, 0x9a, 2))
    for i in 0..<width {
      let at = offset + i
      let byte = UInt8(truncatingIfNeeded: value >> (8 * i))
      func merge(_ old: UInt32, _ first: Int) -> UInt32 {
        let shift = 8 * (at - first)
        return old & ~(255 << shift) | UInt32(byte) << shift
      }
      switch at {
      case 4...5: nextCommand = merge(nextCommand, 4) & 0x406
      case 16...19: nextBase = merge(nextBase, 16)
      case 0x3c, 0x88, 0x8c..<0x94, 0xa9...0xb1: config[at] = byte
      case 0xa8: config[at] = byte & 0xfc
      case 0xa6:
        guard !msix.enabled || byte & 1 == 0 else { return false }
        config[at] = 0x80 | byte & 1
        updateLine()
      case 0x9b: ctrl = (ctrl & 0x7ff) | UInt32(byte & 0xc0) << 8
      default: break  // reserved/read-only
      }
    }
    if UInt16(nextCommand) != command {
      let enable = nextCommand & 4 != 0
      guard enable == master || backend.setBusMaster(enable) else { return false }
      command = UInt16(nextCommand)
      put(4, 2, nextCommand)
      updateLine()
    }
    base = nextBase & ~(barSize - 1)
    put(16, 4, base)
    if offset <= 0x9b && offset + width > 0x9b {
      let enable = ctrl & 0x8000 != 0
      guard !enable || !msi else { return false }
      put(0x9a, 2, ctrl)
      let delivered = msix.control(enable: enable, mask: ctrl & 0x4000 != 0, inject: inject)
      updateLine()
      return delivered
    }
    return true
  }

  func read(_ at: Int, _ width: Int) -> UInt64? {
    if at < 56 { return common.read(offset: at, width: width) }
    if at == 64 && width == 1 {
      let old = isr
      isr = 0
      updateLine()
      return UInt64(old)
    }
    if at >= 256 && at + width <= 256 + configLength {
      return backend.readConfig(offset: at - 256, width: width).map { $0 & mask(width) }
    }
    if at >= table && at + width <= pending {
      guard width == 4 || width == 8, let lo = msix.readTable(offset: at - table) else {
        return nil
      }
      return width == 4
        ? UInt64(lo) : UInt64(msix.readTable(offset: at - table + 4)!) << 32 | UInt64(lo)
    }
    if at >= pending, width == 4 || width == 8,
      let word = msix.readPending(word: (at - pending) / 8)
    {
      return word >> ((at - pending) % 8 * 8) & mask(width)
    }
    return nil
  }
  func write(_ at: Int, _ width: Int, _ value: UInt64) -> Bool {
    if at < 56 {
      let ok = common.write(
        offset: at, width: width, value: value, ram: backend.ram,
        pin: { [backend] in backend.pin(queue: $0, layout: $1) }, reset: backend.reset)
      if ok && at == 20 && value == 0 {
        isr = 0
        updateLine()
      }
      return ok
    }
    if at >= 256 && at + width <= 256 + configLength {
      return backend.writeConfig(offset: at - 256, width: width, value: value)
    }
    if at >= 4096 && at < 4096 + notifyLength {
      guard master, width == 2, at % 4 == 0 else { return false }
      return common.notify(
        slot: UInt16((at - 4096) / 4), queue: UInt16(value), service: backend.kick)
    }
    if at >= table && at + width <= pending && (width == 4 || width == 8) {
      guard
        msix.writeTable(
          offset: at - table, value: UInt32(truncatingIfNeeded: value), inject: inject)
      else { return false }
      return width == 4
        || msix.writeTable(offset: at - table + 4, value: UInt32(value >> 32), inject: inject)
    }
    return false
  }
}
