/// One fixed-size record per slot; the hook and map owner serialize producers.
/// Only the consumer cursor is writable by user space. The kernel holds the
/// backing grant until detachment drains all producers and unmaps all readers.
public struct ProbeRingMap: ~Copyable {
  public let capacity: UInt64
  public let recordBytes: Int
  private let slots: UnsafeMutableRawBufferPointer
  public private(set) var head: UInt64 = 0
  public private(set) var dropped: UInt64 = 0

  public init?(shape: ProbeMapShape, byteQuota: UInt64, slots: UnsafeMutableRawBufferPointer) {
    guard shape.kind == .ring, shape.elementSize <= 256,
      validMap(shape, 1, byteQuota), slots.baseAddress != nil,
      UInt64(slots.count) / shape.capacity == shape.elementSize,
      UInt64(slots.count) % shape.capacity == 0
    else { return nil }
    self.capacity = shape.capacity
    self.recordBytes = Int(shape.elementSize)
    self.slots = slots
    // Clear before the read-only user mapping is exposed, not on the hit path.
    for i in slots.indices { slots[i] = 0 }
  }

  // read accesses the verified hook schema, never a pointer from probe code.
  // Failed reservations make no callbacks.
  public mutating func emit(
    hook: ProbeHook, bytes: Int, consumed: UInt64,
    read: (Int) -> UInt8, publish: (UInt64) -> Void
  ) -> Bool {
    guard effectAllowed(hook, .ringWrite), bytes == recordBytes else { return false }
    guard consumed <= head, head - consumed < capacity, head < UInt64.max else {
      if dropped < UInt64.max { dropped += 1 }
      return false
    }
    let start = Int(head % capacity) * recordBytes
    for i in 0..<recordBytes { slots[start + i] = read(i) }
    head += 1
    publish(head)  // release; trace service acquires before copying a record
    return true
  }
}
