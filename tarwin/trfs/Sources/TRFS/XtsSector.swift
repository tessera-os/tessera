/// Two little-endian halves of one AES input/output block.
public struct CipherBlock: Equatable {
  public let low: UInt64, high: UInt64
  public init(low: UInt64, high: UInt64) {
    self.low = low
    self.high = high
  }
  fileprivate func xor(_ b: Self) -> Self { Self(low: low ^ b.low, high: high ^ b.high) }
  fileprivate var nextTweak: Self {
    Self(low: (low << 1) ^ (0x87 & (0 &- (high >> 63))), high: (high << 1) | (low >> 63))
  }
}

/// Kernel-resolved, pinned key object with two distinct AES-256 schedules.
/// No key bytes, schedules or callable cipher capability enter a driver.
public protocol XtsCipher: ~Copyable {
  var keyObject: UInt64 { get }
  mutating func encryptTweak(_ block: CipherBlock) -> CipherBlock?
  mutating func data(_ block: CipherBlock, decrypt: Bool) -> CipherBlock?
}

/// Allocator-verified contiguous physical range and its private CPU mapping.
public struct SectorPin {
  public let physical: UInt64, bytes: UnsafeMutableRawBufferPointer
  public init?(physical: UInt64, bytes: UnsafeMutableRawBufferPointer) {
    guard bytes.baseAddress != nil, bytes.count >= 16, bytes.count <= 16 * 1024 * 1024,
      bytes.count % 16 == 0,
      physical <= UInt64.max - UInt64(bytes.count - 1)
    else { return nil }
    self.physical = physical
    self.bytes = bytes
  }
}
public enum SectorResult: Equatable { case waiting, completed, failed, inactive }

/// A one-shot transfer. Pin the key, cache and ciphertext storage through
/// finish, exclude clients from the cache and serialize callbacks. Only the
/// exact staging range is ever granted to the device. `issue` may report
/// false only if *no* device access occurred or remains possible.
public struct XtsSector: ~Copyable {
  private let unit: EncryptedUnit, cache: SectorPin, stage: SectorPin
  private enum Phase { case fresh, reading, writing, finished }
  private var phase: Phase = .fresh
  private var completion: Bool?
  public init?(unit: EncryptedUnit, cache: SectorPin, staging: SectorPin) {
    func separate(_ a: UInt64, _ b: UInt64, _ n: Int) -> Bool {
      (a > b ? a - b : b - a) >= UInt64(n)
    }
    guard unit.keyObject != 0, cache.bytes.count == staging.bytes.count,
      separate(cache.physical, staging.physical, cache.bytes.count),
      separate(
        UInt64(UInt(bitPattern: cache.bytes.baseAddress)),
        UInt64(UInt(bitPattern: staging.bytes.baseAddress)), cache.bytes.count)
    else { return nil }
    self.unit = unit
    self.cache = cache
    stage = staging
  }
  private func transform<C: XtsCipher & ~Copyable>(decrypt: Bool, cipher: inout C) -> Bool {
    guard cipher.keyObject == unit.keyObject,
      var tweak = cipher.encryptTweak(CipherBlock(low: unit.tweak, high: 0))
    else { return false }
    let src = (decrypt ? stage : cache).bytes
    let dst = (decrypt ? cache : stage).bytes
    var i = 0
    while i < src.count {
      let b = CipherBlock(
        low: UInt64(littleEndian: src.loadUnaligned(fromByteOffset: i, as: UInt64.self)),
        high: UInt64(littleEndian: src.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)))
      guard let transformed = cipher.data(b.xor(tweak), decrypt: decrypt) else { return false }
      let out = transformed.xor(tweak)
      dst.storeBytes(of: out.low.littleEndian, toByteOffset: i, as: UInt64.self)
      dst.storeBytes(of: out.high.littleEndian, toByteOffset: i + 8, as: UInt64.self)
      tweak = tweak.nextTweak
      i += 16
    }
    return true
  }
  public mutating func begin<C: XtsCipher & ~Copyable>(
    read: Bool, cipher: inout C,
    erase: (UnsafeMutableRawBufferPointer) -> Void, issue: (UInt64, UInt64, Int, Bool) -> Bool
  ) -> Bool {
    guard phase == .fresh else { return false }
    phase = .finished
    guard cipher.keyObject == unit.keyObject else {
      erase(stage.bytes)
      if read { erase(cache.bytes) }
      return false
    }
    if read {
      erase(stage.bytes)
    } else if !transform(decrypt: false, cipher: &cipher) {
      erase(stage.bytes)
      return false
    }
    guard issue(unit.block, stage.physical, stage.bytes.count, read) else {
      if read { erase(cache.bytes) }
      erase(stage.bytes)
      return false
    }
    phase = read ? .reading : .writing
    return true
  }
  /// The first completion is terminal; nil reports an I/O error. Drain
  /// must synchronously revoke DMA and perform required cache maintenance,
  /// including on device loss. False retains both pins without touching them.
  public mutating func finish<C: XtsCipher & ~Copyable>(
    transferred: Int?, cipher: inout C,
    drain: () -> Bool, erase: (UnsafeMutableRawBufferPointer) -> Void
  ) -> SectorResult {
    guard phase == .reading || phase == .writing else { return .inactive }
    if completion == nil { completion = transferred == stage.bytes.count }
    guard drain() else { return .waiting }
    var ok = completion == true
    if phase == .reading {
      ok = ok && transform(decrypt: true, cipher: &cipher)
      if !ok { erase(cache.bytes) }
    }
    erase(stage.bytes)
    phase = .finished
    return ok ? .completed : .failed
  }
}
