import KCore
import Tarboot
import TarwinLoader

public typealias W0Version = (UInt8, UInt8, UInt8)

/// All fields originate in trusted guest state, never the ESP. Slot A = 0,
/// B = 1. A missing clock or rollback counter fails closed.
public struct W0Policy {
  let machine: UInt16, baselineSupported: Bool, trustedUTC: UInt64?, train: W0Version,
    tir: W0Version
  let addressLimit: UInt64, securityFloor: UInt64?, slot: UInt8, debugEmulator: Bool
  public init(
    machine: UInt16, baselineSupported: Bool, trustedUTC: UInt64?, train: W0Version, tir: W0Version,
    addressLimit: UInt64, securityFloor: UInt64?, slot: UInt8, debugEmulator: Bool
  ) {
    self.machine = machine
    self.baselineSupported = baselineSupported
    self.trustedUTC = trustedUTC
    self.train = train
    self.tir = tir
    self.addressLimit = addressLimit
    self.securityFloor = securityFloor
    self.slot = slot
    self.debugEmulator = debugEmulator
  }
}

/// Borrow of the exact authorized member. The owner must keep the original
/// archive mapping pinned, immutable and inaccessible to DMA through placement.
public struct W0Kernel {
  public let bytes: UnsafeRawBufferPointer
  public let range: Range<Int>
  public let image: InspectedImage
  public let securityVersion: UInt64
}
private struct Source: ByteSource {
  let raw: UnsafeRawBufferPointer
  func byteCount() -> UInt64 { UInt64(raw.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { raw[Int(offset)] }
}
private func view(_ b: UnsafeRawBufferPointer, _ r: Range<Int>) -> UnsafeRawBufferPointer {
  UnsafeRawBufferPointer(rebasing: b[r])
}
private func literal(_ s: StaticString) -> UnsafeRawBufferPointer {
  UnsafeRawBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount)
}
private func equal(_ b: UnsafeRawBufferPointer, _ s: StaticString) -> Bool {
  let t = literal(s)
  guard t.count == b.count else { return false }
  for i in b.indices where b[i] != t[i] { return false }
  return true
}
private func word(_ b: UnsafeRawBufferPointer, _ p: Int) -> UInt32 {
  UInt32(littleEndian: b.loadUnaligned(fromByteOffset: p, as: UInt32.self))
}
private func wide(_ b: UnsafeRawBufferPointer, _ p: Int) -> UInt64 {
  UInt64(littleEndian: b.loadUnaligned(fromByteOffset: p, as: UInt64.self))
}
private func digestByte(_ cv: BlakeCv, _ i: Int) -> UInt8 {
  let word: UInt32
  switch i >> 2 {
  case 0: word = cv.w0
  case 1: word = cv.w1
  case 2: word = cv.w2
  case 3: word = cv.w3
  case 4: word = cv.w4
  case 5: word = cv.w5
  case 6: word = cv.w6
  default: word = cv.w7
  }
  return UInt8(truncatingIfNeeded: word >> (8 * (i & 3)))
}
private func matches(_ cv: BlakeCv, _ b: UnsafeRawBufferPointer, _ p: Int) -> Bool {
  for i in 0..<32 where b[p + i] != digestByte(cv, i) { return false }
  return true
}
private func authenticated(
  _ envelope: UnsafeRawBufferPointer, _ enrolled: UnsafeRawBufferPointer,
  _ msg: UnsafeRawBufferPointer, _ stack: UnsafeMutableBufferPointer<BlakeCv>,
  _ work: UnsafeMutableBufferPointer<Int32>
) -> Bool {
  guard envelope.count <= 65536, let e = HybridEnvelope(envelope, descriptor: 0..<envelope.count),
    let chain = bootSetDigest(view(envelope, e.chain), scratch: stack), matches(chain, enrolled, 20)
  else { return false }
  return verifyEd25519(
    key: view(enrolled, 52..<84), message: msg, signature: view(envelope, e.ed25519))
    && verifyMLDSA65(
      key: view(enrolled, 84..<2036), message: msg,
      context: UnsafeRawBufferPointer(start: nil, count: 0), signature: view(envelope, e.mldsa65),
      work: work)
}
private func member(
  _ a: UnsafeRawBufferPointer, _ name: StaticString, _ stack: UnsafeMutableBufferPointer<BlakeCv>
) -> Range<Int>? {
  let m = findBootMember(Source(raw: a), name: Source(raw: literal(name)))
  guard m.validArchive, m.found, m.compression == 0, m.size > 0 else { return nil }
  let range = Int(m.offset)..<Int(m.offset + m.size)
  guard let cv = bootSetDigest(view(a, range), scratch: stack), matches(cv, a, Int(m.digestAt))
  else { return nil }
  return range
}
private func version(_ b: UnsafeRawBufferPointer, _ at: Int, _ v: W0Version) -> Bool {
  b[at] == v.0 && b[at + 1] == v.1 && b[at + 2] == v.2
}
private func restrictedKernel(_ b: UnsafeRawBufferPointer, _ image: InspectedImage, _ p: W0Policy)
  -> Bool
{
  let notes = image.notes
  guard let role = notes.profile, role.count == 2, b[role.lowerBound] == 3,
    b[role.lowerBound + 1] == 4,
    let grants = notes.entitlements, equal(view(b, grants), "[]"),
    let train = notes.train, train.count == 9, version(b, train.lowerBound, p.train),
    version(b, train.lowerBound + 3, p.tir), version(b, train.lowerBound + 6, p.train),
    let target = notes.target, matchesW0Baseline(view(b, target), machine: p.machine),
    notes.finalizer == nil,
    let section = image.loaderRecords,
    let d = inspectLoaderRecords(view(b, section), addressLimit: p.addressLimit),
    d[.relative].count == 0, d[.authenticated].count == 0, d[.imports].count == 0,
    d[.runtime].count == 0, d[.dispatch].count == 0,
    d[.tls].count == 0, d[.features].count == 0,
    word(b, section.lowerBound + d[.gpu].bytes.lowerBound) == 0
  else { return false }
  var notesCount = 0
  for at in stride(
    from: image.programHeaders.lowerBound, to: image.programHeaders.upperBound, by: 56)
  {
    if word(b, at) == 4 {
      notesCount += 1
      continue
    }
    guard word(b, at) == 1, word(b, at + 4) == 4 || word(b, at + 4) == 5,
      wide(b, at + 32) == wide(b, at + 40)
    else { return false }
    // Note descriptors must not share a mapped page, even a read-only page.
    let page = imagePage(p.machine)
    let start = wide(b, at + 8)
    let length = wide(b, at + 32)
    if length > 0, let id = notes.buildID, let sig = notes.signature {
      let mapped = Int(start / page * page)..<Int((start + length + page - 1) / page * page)
      if mapped.overlaps(id) || mapped.overlaps(sig) { return false }
    }
  }
  // InspectSigningCandidate has already bounded the entire section table.
  let header = Int(wide(b, 40))
  let count = Int(UInt16(littleEndian: b.loadUnaligned(fromByteOffset: 60, as: UInt16.self)))
  for i in 0..<count where wide(b, header + 64 * i + 8) & 0x401 != 0 { return false }
  return notesCount == 1
}

/// QEMU-only. All scratch buffers must be private, correctly aligned, disjoint
/// from each other and from the immutable inputs. No verification callback.
public func authorizeQEMUStage0(
  archive: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer,
  enrollment: UnsafeRawBufferPointer, policy: W0Policy, hashes: UnsafeMutableBufferPointer<BlakeCv>,
  polynomials: UnsafeMutableBufferPointer<Int32>, message: UnsafeMutableRawBufferPointer
) -> W0Kernel? {
  guard policy.debugEmulator, policy.baselineSupported, policy.slot <= 1,
    let utc = policy.trustedUTC, let floor = policy.securityFloor,
    enrollment.count == 2036, word(enrollment, 0) == 0x3145_5154, utc >= wide(enrollment, 4),
    utc <= wide(enrollment, 12),
    hashes.count >= 54, polynomials.count >= 2048, message.count >= 1024,
    archive.count >= 24, archive.count <= 64 * 1024 * 1024, word(archive, 8) == 2,
    let digest = bootSetDigest(archive, scratch: hashes)
  else { return nil }
  let domain = literal("Tarwin boot set v1")
  for i in domain.indices { message[i] = domain[i] }
  message[domain.count] = 0
  for i in 0..<32 { message[domain.count + 1 + i] = digestByte(digest, i) }
  let msg = UnsafeRawBufferPointer(message)
  guard authenticated(signature, enrollment, view(msg, 0..<domain.count + 33), hashes, polynomials),
    let conf = member(archive, "boot.json", hashes), let range = member(archive, "kernel", hashes),
    !conf.overlaps(range),
    let settings = DebugBootConfig(view(archive, conf)), settings.slot == policy.slot,
    settings.securityVersion >= floor
  else { return nil }
  let kernel = view(archive, range)
  guard
    let image = inspectSigningCandidate(
      kernel, machine: policy.machine, addressLimit: policy.addressLimit, finalized: false,
      requiresEntry: true, scratch: hashes),
    restrictedKernel(kernel, image, policy), let sig = image.notes.signature,
    let n = nativeSigningMessage(kernel, notes: image.notes, into: message),
    authenticated(view(kernel, sig), enrollment, view(msg, 0..<n), hashes, polynomials)
  else { return nil }
  return W0Kernel(
    bytes: kernel, range: range, image: image, securityVersion: settings.securityVersion)
}
