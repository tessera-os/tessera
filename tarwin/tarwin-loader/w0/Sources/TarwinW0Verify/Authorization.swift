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
func view(_ b: UnsafeRawBufferPointer, _ r: Range<Int>) -> UnsafeRawBufferPointer {
  UnsafeRawBufferPointer(rebasing: b[r])
}
private func literal(_ s: StaticString) -> UnsafeRawBufferPointer {
  UnsafeRawBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount)
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
func member(
  _ a: UnsafeRawBufferPointer, _ name: StaticString, _ stack: UnsafeMutableBufferPointer<BlakeCv>
) -> Range<Int>? {
  let m = findBootMember(Source(raw: a), name: Source(raw: literal(name)))
  guard m.validArchive, m.found, m.compression == 0, m.size > 0 else { return nil }
  let range = Int(m.offset)..<Int(m.offset + m.size)
  guard let cv = bootSetDigest(view(a, range), scratch: stack), matches(cv, a, Int(m.digestAt))
  else { return nil }
  return range
}

/// QEMU-only. All scratch buffers must be private, correctly aligned, disjoint
/// from each other and from the immutable inputs. No verification callback.
public func authorizeQEMUStage0(
  archive: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer,
  enrollment: UnsafeRawBufferPointer, policy: W0Policy, hashes: UnsafeMutableBufferPointer<BlakeCv>,
  polynomials: UnsafeMutableBufferPointer<Int32>, message: UnsafeMutableRawBufferPointer
) -> W0Kernel? {
  authorizedKernel(
    archive: archive, signature: signature, enrollment: enrollment, policy: policy,
    hashes: hashes, polynomials: polynomials, message: message, members: 2)?.0
}

func validPin(_ enrollment: UnsafeRawBufferPointer, utc: UInt64) -> Bool {
  enrollment.count == 2036 && word(enrollment, 0) == 0x3145_5154 && utc >= wide(enrollment, 4)
    && utc <= wide(enrollment, 12)
}

func authenticatedImage(
  _ file: UnsafeRawBufferPointer, _ image: InspectedImage,
  enrollment: UnsafeRawBufferPointer, hashes: UnsafeMutableBufferPointer<BlakeCv>,
  polynomials: UnsafeMutableBufferPointer<Int32>, message: UnsafeMutableRawBufferPointer
) -> Bool {
  guard let sig = image.notes.signature,
    let n = nativeSigningMessage(file, notes: image.notes, into: message)
  else { return false }
  return authenticated(
    view(file, sig), enrollment, view(.init(message), 0..<n), hashes, polynomials)
}

func authorizedKernel(
  archive: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer,
  enrollment: UnsafeRawBufferPointer, policy: W0Policy, hashes: UnsafeMutableBufferPointer<BlakeCv>,
  polynomials: UnsafeMutableBufferPointer<Int32>, message: UnsafeMutableRawBufferPointer,
  members: UInt32
) -> (W0Kernel, Range<Int>)? {
  guard policy.debugEmulator, policy.baselineSupported, policy.slot <= 1,
    let utc = policy.trustedUTC, let floor = policy.securityFloor,
    validPin(enrollment, utc: utc),
    hashes.count >= 54, polynomials.count >= 2048, message.count >= 1024,
    archive.count >= 24, archive.count <= 64 * 1024 * 1024, word(archive, 8) == members,
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
    let image = inspectW0SigningCandidate(
      kernel, machine: policy.machine, train: policy.train, tir: policy.tir,
      addressLimit: policy.addressLimit, scratch: hashes),
    authenticatedImage(
      kernel, image, enrollment: enrollment, hashes: hashes,
      polynomials: polynomials, message: message)
  else { return nil }
  return (
    W0Kernel(
      bytes: kernel, range: range, image: image, securityVersion: settings.securityVersion), conf
  )
}
