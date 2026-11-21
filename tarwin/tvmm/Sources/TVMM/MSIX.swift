// One PCI function's MSI-X table and read-only pending bit array. Message
// addresses are guest interrupt messages, never addresses to write on the host.
public struct GuestMSIX {
  private struct Entry {
    var address: UInt64 = 0
    var data: UInt32 = 0
    var masked = true
    var pending = false
  }

  private var entries: [Entry]
  public private(set) var enabled = false
  public private(set) var functionMasked = false
  public var count: Int { entries.count }
  public typealias Inject = (_ guestMessageAddress: UInt64, _ data: UInt32) -> Bool

  public init?(count: Int) {
    guard (1...2048).contains(count) else { return nil }
    entries = Array(repeating: Entry(), count: count)
  }

  public func readTable(offset: Int) -> UInt32? {
    guard offset >= 0, offset < count * 16, offset % 4 == 0 else { return nil }
    let e = entries[offset / 16]
    switch offset % 16 {
    case 0: return UInt32(truncatingIfNeeded: e.address)
    case 4: return UInt32(e.address >> 32)
    case 8: return e.data
    default: return e.masked ? 1 : 0
    }
  }

  public func readPending(word: Int) -> UInt64? {
    guard word >= 0, word <= (count - 1) / 64 else { return nil }
    let start = word * 64
    var bits: UInt64 = 0
    for i in start..<min(count, start + 64) where entries[i].pending { bits |= 1 << (i - start) }
    return bits
  }

  public mutating func writeTable(offset: Int, value: UInt32, inject: Inject) -> Bool {
    guard offset >= 0, offset < count * 16, offset % 4 == 0 else { return false }
    let slot = offset / 16
    switch offset % 16 {
    case 0:
      entries[slot].address = entries[slot].address & 0xffff_ffff_0000_0000 | UInt64(value & ~3)
    case 4: entries[slot].address = UInt64(value) << 32 | entries[slot].address & 0xffff_ffff
    case 8: entries[slot].data = value
    default:
      entries[slot].masked = value & 1 != 0
      return deliver(slot, inject)
    }
    return true
  }

  public mutating func control(enable: Bool, mask: Bool, inject: Inject) -> Bool {
    enabled = enable
    functionMasked = mask
    guard enabled && !functionMasked else { return true }
    var ok = true
    for i in entries.indices where !deliver(i, inject) { ok = false }
    return ok
  }

  public mutating func signal(_ vector: Int, inject: Inject) -> Bool {
    guard enabled, entries.indices.contains(vector) else { return false }
    entries[vector].pending = true
    return deliver(vector, inject)
  }

  private mutating func deliver(_ vector: Int, _ inject: Inject) -> Bool {
    let entry = entries[vector]
    guard entry.pending, enabled, !functionMasked, !entry.masked else { return true }
    guard inject(entry.address, entry.data) else { return false }
    entries[vector].pending = false
    return true
  }
}
