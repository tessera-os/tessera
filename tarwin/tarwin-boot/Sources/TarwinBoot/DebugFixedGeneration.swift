/// A debug harness claim, not entropy, a live device, or entry authority.
public struct DebugQEMUFixedGeneration: Equatable {
  public let low, high: UInt64
  public init?(low: UInt64, high: UInt64) {
    guard low | high != 0 else { return nil }
    self.low = low
    self.high = high
  }

  static let revision: UInt8 = 0x81
  static let label: UInt64 = 0x314e_4547_5147_4244 // "DBGQGEN1", little endian

  /// Only the exclusive debug loader calls this on an unpublished, complete
  /// revision-1 block. All default readers reject the resulting revision.
  public func encode(in block: UnsafeMutableRawBufferPointer) -> Bool {
    guard block.count == 4096, block[7] == 1, block[177] == 2,
      block.loadUnaligned(as: UInt32.self).littleEndian == 0x4249_4254 else { return false }
    for i in 216..<4096 where block[i] != 0 { return false }
    func emit(_ offset: Int, _ word: UInt64) {
      for i in 0..<8 { block[offset+i] = UInt8(truncatingIfNeeded: word >> (8*i)) }
    }
    emit(216, Self.label)
    emit(224, low)
    emit(232, high)
    block[7] = Self.revision
    return true
  }

  static func decode(_ block: UnsafeRawBufferPointer) -> Self? {
    guard block.count >= 4096, block[7] == revision, block[177] == 2 else { return nil }
    func word(_ offset: Int) -> UInt64 {
      UInt64(littleEndian: block.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
    guard word(216) == label else { return nil }
    return Self(low: word(224), high: word(232))
  }
}
