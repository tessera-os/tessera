/// Sleepable trusted block binding. Return from transfer ONLY after terminal
/// completion, DMA revocation and cache maintenance, even on errors or unplug.
/// Until then it owns the pins; no timeout can substitute for a drain.
/// The driver receives a ciphertext pin, never a CPU pointer or a key.
public protocol TrfsRetiredBlockIO {
  var blocks: UInt64 { get }
  func transfer(_ block: UInt64, physical: UInt64, count: Int, read: Bool) -> Int?
  func flush() -> Bool
  func erase(_ bytes: UnsafeMutableRawBufferPointer)
  func sha256(_ bytes: UnsafeRawBufferPointer) -> TrfsDigest
}

/// Serialize all uses of this binding. The cipher and both 4 KiB pins are
/// kernel-owned, disjoint from the volume's private scratch and client spans,
/// and remain live until the last operation returns.
public struct TrfsEncryptedMedia<IO: TrfsRetiredBlockIO, C: XtsCipher>: TrfsMedia {
  private let io: IO, cipher: UnsafeMutablePointer<C>, cache: SectorPin, stage: SectorPin
  private let key: UInt64
  public var blocks: UInt64 { io.blocks }
  public init?(
    io: IO, cipher: UnsafeMutablePointer<C>, privatePage: SectorPin, ciphertext: SectorPin
  ) {
    let key = cipher.pointee.keyObject
    guard privatePage.bytes.count == 4096, ciphertext.bytes.count == 4096,
      XtsSector(
        unit: .init(block: 0, tweak: 0, keyObject: key), cache: privatePage, staging: ciphertext)
        != nil
    else { return nil }
    self.io = io
    self.cipher = cipher
    self.cache = privatePage
    self.stage = ciphertext
    self.key = key
  }
  private func valid(_ bytes: UnsafeRawBufferPointer) -> Bool {
    guard bytes.count == 4096, let address = bytes.baseAddress else { return false }
    let a = UInt(bitPattern: address)
    for base in (0..<2) {
      let b = UInt(bitPattern: base == 0 ? cache.bytes.baseAddress : stage.bytes.baseAddress)
      if (a > b ? a - b : b - a) < 4096 { return false }
    }
    return true
  }
  private func operate(_ block: UInt64, read: Bool) -> Bool {
    guard block < blocks,
      var t = XtsSector(
        unit: .init(block: block, tweak: block, keyObject: key),
        cache: cache, staging: stage)
    else { return false }
    var transferred: Int?
    let ok = t.begin(read: read, cipher: &cipher.pointee, erase: io.erase) {
      block, pin, n, direction in
      transferred = io.transfer(block, physical: pin, count: n, read: direction)
      return true  // including a terminal short/error completion
    }
    guard ok else { return false }
    return t.finish(
      transferred: transferred, cipher: &cipher.pointee, drain: { true }, erase: io.erase)
      == .completed
  }
  public func read(_ block: UInt64, into dst: UnsafeMutableRawBufferPointer) -> Bool {
    guard valid(.init(dst)) else { return false }
    defer { io.erase(cache.bytes) }
    guard operate(block, read: true) else { return false }
    dst.copyMemory(from: .init(cache.bytes))
    return true
  }
  public func write(_ block: UInt64, from bytes: UnsafeRawBufferPointer) -> Bool {
    guard valid(bytes) else { return false }
    defer { io.erase(cache.bytes) }
    cache.bytes.copyMemory(from: bytes)
    return operate(block, read: false)
  }
  public func flush() -> Bool { io.flush() }
  public func sha256(_ bytes: UnsafeRawBufferPointer) -> TrfsDigest { io.sha256(bytes) }
}
