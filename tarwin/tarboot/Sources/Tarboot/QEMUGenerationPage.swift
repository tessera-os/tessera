/// Live VMGenID on a trusted QEMU debug machine profile whose management
/// rotates the device before *every* restore. Inventory cannot attest that
/// policy. Never use the boot GUID as the epoch after discovery.
public struct QEMUGenerationPage {
  public let physical: UInt64

  public static func discover<R: QEMUConfigReader>(
    _ reader: inout R, pinnedPage: UInt64, regions: UnsafeBufferPointer<FirmwareRegion>,
    readWord: (UInt64) -> UInt64?
  ) -> Self? {
    guard case .advertised(let addr, let guid) = qemuGenerationDevice(&reader) else { return nil }
    func le64() -> UInt64 {
      var word: UInt64 = 0
      for i in 0..<8 { word |= UInt64(reader.readByte()) << (8 * i) }
      return word
    }
    reader.select(addr)
    let p = le64()
    // QEMU writes a 32-bit VGIA and firmware adds the SDT suppressor.
    guard p > 4096, p < 1 << 32, p & 4095 == 40 else { return nil }
    let page = p - 40
    guard page == pinnedPage else { return nil }
    var reserved = false
    for i in 0..<regions.count {
      let r = regions[i]
      let (end, overflow) = r.base.addingReportingOverflow(r.length)
      guard !overflow, r.length > 0 else { return nil }
      guard r.base < page + 4096 && page < end else { continue }
      guard !reserved, r.type == 10, r.attributes & 8 != 0, r.attributes & 0x2000 == 0,
        r.base <= page, page + 4096 <= end else { return nil }
      reserved = true
    }
    guard reserved else { return nil }
    reader.select(guid)
    for _ in 0..<40 { _ = reader.readByte() }
    let low = le64(), high = le64()
    let result = Self(physical: p)
    guard let current = result.sample(readWord: readWord),
      current.0 == low, current.1 == high else { return nil }
    return result
  }

  /// Caller retains a read-only, normal write-back kernel mapping of the
  /// reserved page. Use ordered volatile loads, not a cached Swift tuple.
  public func sample(readWord: (UInt64) -> UInt64?) -> (UInt64, UInt64)? {
    guard let a = readWord(physical), let b = readWord(physical + 8), a | b != 0,
      readWord(physical) == a, readWord(physical + 8) == b else { return nil }
    return (a, b)
  }
}
