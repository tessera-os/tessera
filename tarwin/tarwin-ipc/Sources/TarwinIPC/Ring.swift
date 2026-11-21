// A.4: capture these fields from untrusted shared memory once at attach.
public enum RingFormat {
  public static let magic: UInt32 = 0x474e_5254
  public static let version: UInt16 = 1
  public static let requestProducer: UInt64 = 64
  public static let requestConsumer: UInt64 = 128
  public static let requestProducerIdle: UInt64 = 192
  public static let requestConsumerIdle: UInt64 = 256
  public static let completionProducer: UInt64 = 320
  public static let completionConsumer: UInt64 = 384
  public static let completionProducerIdle: UInt64 = 448
  public static let completionConsumerIdle: UInt64 = 512
  public static let records: UInt64 = 4096
}

public struct RingGeometry {
  public let count: UInt32
  public let stride: UInt32

  public func valid() -> Bool {
    if count < 64 || count > 65536 { return false }
    if (count & (count - 1)) != 0 { return false }
    return stride == 64 || stride == 128
  }

  public func fits(_ mappingBytes: UInt64) -> Bool {
    if !valid() { return false }
    return RingFormat.records + 2 * UInt64(count) * UInt64(stride) <= mappingBytes
  }

  // Call after fits(). Neither queue uses the header again after attach.
  public func offset(_ index: UInt32, _ completion: Bool) -> UInt64 {
    let slot = index & (count - 1)
    var base = RingFormat.records
    if completion { base += UInt64(count) * UInt64(stride) }
    return base + UInt64(slot) * UInt64(stride)
  }

  public init(count: UInt32, stride: UInt32) {
    self.count = count
    self.stride = stride
  }
}

public func ringHeaderAllowed(_ magic: UInt32, _ version: UInt16, _ flags: UInt16) -> Bool {
  return magic == RingFormat.magic && version == RingFormat.version && flags == 0
}

// All positions are logical monotonic u32 indices, not masked offsets.
// Compare a peer's acquire-loaded cursor with its last accepted value.
public func ringProducerValid(
  _ last: UInt32, _ producer: UInt32, _ consumed: UInt32, _ count: UInt32
) -> Bool {
  if producer < last || producer < consumed { return false }
  return producer - consumed <= count
}

public func ringConsumerValid(_ last: UInt32, _ consumer: UInt32, _ produced: UInt32) -> Bool {
  return consumer >= last && consumer <= produced
}
