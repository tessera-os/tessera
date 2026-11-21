/// BLAKE3 derive_key, 32-byte output, for bounded seed material. This is
/// a KDF, not password stretching or a substitute for a trusted source.
public func deriveSmallBlakeKey(context: StaticString, material: UnsafeRawBufferPointer) -> BlakeCv?
{
  func oneChunk(_ input: UnsafeRawBufferPointer, key: BlakeCv, mode: UInt32) -> BlakeCv {
    let view = DigestView(bytes: input, zeros: 0..<0, omit: 0..<0)
    var cv = key
    var at = 0
    repeat {
      let n = min(64, input.count - at)
      let end = at + n
      let flags = mode | (at == 0 ? 1 : 0) | (end == input.count ? 2 | 8 : 0)
      cv = blakeCompress(
        cv, BlakeBlock(low: view.cv(at, end), high: view.cv(at + 32, end)), 0, UInt32(n), flags)
      at = end
    } while at < input.count
    return cv
  }
  guard context.utf8CodeUnitCount > 0, context.utf8CodeUnitCount <= 1024, material.count <= 1024
  else { return nil }
  let c = UnsafeRawBufferPointer(start: context.utf8Start, count: context.utf8CodeUnitCount)
  return oneChunk(material, key: oneChunk(c, key: initialCv(), mode: 32), mode: 64)
}
