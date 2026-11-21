/// Only bounds into the original immutable snapshot. Structural validity is
/// not evidence of either signature or authority to execute.
public struct HybridEnvelope {
  public let chain: Range<Int>
  public let ed25519: Range<Int>
  public let mldsa65: Range<Int>

  public init?(_ bytes: UnsafeRawBufferPointer, descriptor: Range<Int>) {
    let p = descriptor.lowerBound
    guard p >= 0, descriptor.upperBound <= bytes.count, descriptor.count >= 3382 else { return nil }
    let r = ELFReader(bytes: bytes)
    guard r.u32(p) == 0x3147_5354 else { return nil }
    let n = Int(r.u32(p + 4))
    guard n > 0, descriptor.count == 8 + n + 64 + 3309 else { return nil }
    chain = p + 8..<p + 8 + n
    ed25519 = chain.upperBound..<chain.upperBound + 64
    mldsa65 = ed25519.upperBound..<descriptor.upperBound
  }
}

public func nativeSigningID(
  _ bytes: UnsafeRawBufferPointer, image: InspectedImage,
  scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> BlakeCv? {
  guard let id = image.notes.buildID, let range = image.notes.signature,
    let env = HybridEnvelope(bytes, descriptor: range)
  else { return nil }
  return digestImage(
    bytes, zeros: id, omit: env.ed25519.lowerBound..<env.mldsa65.upperBound, stack: scratch)
}

/// The caller supplies disjoint scratch. The returned count excludes the
/// unused tail; sign precisely that prefix.
public func nativeSigningMessage(
  _ bytes: UnsafeRawBufferPointer, notes: ImageNotes, into output: UnsafeMutableRawBufferPointer
) -> Int? {
  let domain: StaticString = "Tarwin native image v1"
  guard let id = notes.buildID, let train = notes.train, let target = notes.target,
    let ent = notes.entitlements,
    output.count >= domain.utf8CodeUnitCount + 1
  else { return nil }
  var pos = 0
  for i in 0..<domain.utf8CodeUnitCount {
    output[pos] = domain.utf8Start[i]
    pos += 1
  }
  output[pos] = 0
  pos += 1
  func append(_ range: Range<Int>, _ sized: Bool, _ p: inout Int) -> Bool {
    guard range.lowerBound >= 0, range.upperBound <= bytes.count,
      UInt32(exactly: range.count) != nil
    else { return false }
    if sized {
      guard output.count - p >= 4 else { return false }
      for i in 0..<4 {
        output[p] = UInt8(truncatingIfNeeded: range.count >> (i * 8))
        p += 1
      }
    }
    guard range.count <= output.count - p else { return false }
    for i in range {
      output[p] = bytes[i]
      p += 1
    }
    return true
  }
  guard append(id, false, &pos), append(train, true, &pos), append(target, true, &pos),
    append(ent, true, &pos)
  else { return nil }
  return pos
}

/// Validates structural metadata, page separation, all loader records and
/// the canonical ID. Do not map, bind, or execute without authenticating both
/// signatures, the identity chain, platform policy, train and actual CPU.
public func inspectSigningCandidate(
  _ bytes: UnsafeRawBufferPointer, machine: UInt16, addressLimit: UInt64, finalized: Bool,
  requiresEntry: Bool, scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> InspectedImage? {
  guard
    let image = inspectELF(
      bytes, target: machine, addressLimit: addressLimit, finalized: finalized,
      requiresEntry: requiresEntry, requiresLoaderRecords: true),
    let root = nativeSigningID(bytes, image: image, scratch: scratch),
    validatedMetadata(
      bytes, image: image, machine: machine, addressLimit: addressLimit, finalized: finalized,
      root: root) != nil
  else { return nil }
  return image
}

public func bootSetDigest(
  _ bytes: UnsafeRawBufferPointer, scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> BlakeCv? {
  digestImage(bytes, zeros: 0..<0, stack: scratch)
}
