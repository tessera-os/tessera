import KCore
import Tarboot
import TarwinLoader

private struct ArchiveBytes: ByteSource {
  let bytes: UnsafeRawBufferPointer
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
}

/// The right-to-left BLAKE3 frontier for at most 2^54 chunks of 1024 bytes.
/// Initialize in caller-owned storage and reuse between members.
public struct DigestScratch: ~Copyable {
  fileprivate var nodes = InlineArray<54, BlakeCv>(
    repeating:
      BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0))
  public init() {}
}

private func words(_ bytes: UnsafeRawBufferPointer, _ start: UInt64, _ limit: UInt64) -> BlakeCv {
  func word(_ delta: UInt64) -> UInt32 {
    var u: UInt32 = 0
    for i in 0..<4 {
      let at = start + delta + UInt64(i)
      if at < limit { u |= UInt32(bytes[Int(at)]) << (i * 8) }
    }
    return u
  }
  return BlakeCv(
    w0: word(0), w1: word(4), w2: word(8), w3: word(12),
    w4: word(16), w5: word(20), w6: word(24), w7: word(28))
}

/// Compares content against the TIRA directory, not against a platform trust anchor.
/// Inputs are pinned immutable memory for the duration of this call.
public func memberDigestMatches(
  _ bytes: UnsafeRawBufferPointer, digest: UnsafeRawBufferPointer,
  scratch: inout DigestScratch
) -> Bool {
  guard digest.count == 32 else { return false }
  let size = UInt64(bytes.count)
  let count = size == 0 ? 1 : (size - 1) / 1024 + 1
  var n = 0
  for chunk in 0..<count {
    var proof = imageChunk(size, chunk)
    var at = chunk * 1024
    let end = min(size, at + 1024)
    repeat {
      let len = min(end - at, 64)
      let block = BlakeBlock(low: words(bytes, at, end), high: words(bytes, at + 32, end))
      guard proof.absorb(block, UInt32(len)) else { return false }
      at += len
    } while !proof.hashed
    if chunk == count - 1 {
      while n > 0 {
        n -= 1
        guard proof.sibling(scratch.nodes[n]) else { return false }
      }
      return proof.verifies(words(digest, 0, 32))
    }
    var value = proof.chain
    var complete = chunk + 1
    while complete & 1 == 0 {
      guard n > 0 else { return false }
      n -= 1
      value = imageParentCv(scratch.nodes[n], value)
      complete >>= 1
    }
    guard n < 54 else { return false }
    scratch.nodes[n] = value
    n += 1
  }
  return false
}

public enum KernelPreflight {
  case invalidArchive, notFound, compressed, digestMismatch, invalidELF
  /// Directory range is archive-relative; all image ranges are member-relative.
  /// Does not authorize loading, relocation, mapping or branching to the entry.
  case inspected(member: Range<Int>, image: InspectedImage)
}

/// Inspect the raw kernel member of the same immutable archive throughout.
/// The caller still must authenticate the manifest, signer, notes and rollback
/// counter, and keep exactly these bytes pinned through subsequent policy checks.
public func inspectBootKernel(
  _ archive: UnsafeRawBufferPointer, path: UnsafeRawBufferPointer,
  target: UInt16, addressLimit: UInt64, scratch: inout DigestScratch
)
  -> KernelPreflight
{
  let member = findBootMember(ArchiveBytes(bytes: archive), name: ArchiveBytes(bytes: path))
  guard member.validArchive else { return .invalidArchive }
  guard member.found else { return .notFound }
  guard member.compression == 0 else { return .compressed }
  // findBootMember validated the complete directory and bounded both extents
  // by archive.count. A raw member's stored and uncompressed sizes are equal.
  let extent = Int(member.offset)..<Int(member.offset + member.size)
  let bytes = UnsafeRawBufferPointer(rebasing: archive[extent])
  let digest = UnsafeRawBufferPointer(
    rebasing: archive[Int(member.digestAt)..<Int(member.digestAt + 32)])
  guard memberDigestMatches(bytes, digest: digest, scratch: &scratch) else {
    return .digestMismatch
  }
  guard
    let image = inspectELF(
      bytes, target: target, addressLimit: addressLimit,
      finalized: false, requiresEntry: true)
  else { return .invalidELF }
  return .inspected(member: extent, image: image)
}
