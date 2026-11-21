import TarwinLoader

public struct W1UserMember {
  public let bytes: UnsafeRawBufferPointer
  public let range: Range<Int>
  public let layout: EarlyUserImage
}

public struct W1BootSet {
  public let machine: UInt16
  public let kernel: W0Kernel
  public let process, library: W1UserMember
  public let binding: NativeFunctionBinding
  /// SHA-256 bank event digests of the exact archive and authorized boot.json bytes.
  public let archiveSHA256, configurationSHA256: InlineArray<32, UInt8>
  /// SHA-256 bank event digest of the entire immutable signed init member.
  public let initSHA256: InlineArray<32, UInt8>
}

/// Verification only, debug QEMU. Pin both enrollments and the SDK
/// contract independently. Borrow all image bytes from the single protected
/// snapshot; never reopen the archive by name. This does not publish a log,
/// extend a PCR, install a mapping, sign a slot pointer or grant thread entry.
public func authorizeQEMUStage1(
  archive: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer,
  enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer, policy: W0Policy,
  contract: EarlyRIDLContract,
  hashes: UnsafeMutableBufferPointer<BlakeCv>, polynomials: UnsafeMutableBufferPointer<Int32>,
  message: UnsafeMutableRawBufferPointer
) -> W1BootSet? {
  guard contract.isW1ProcessCurrent else { return nil }
  return verifyStage1(
    archive: archive, signature: signature, enrollment: enrollment,
    systemEnrollment: systemEnrollment, policy: policy, initEntryTag: 0x4d3e_7643,
    contract: contract, hashes: hashes, polynomials: polynomials, message: message)
}

// The interop corpus has its own entry tag; it must never authorize a launch.
func verifyStage1(
  archive: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer,
  enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer, policy: W0Policy,
  initEntryTag: UInt32, contract: EarlyRIDLContract,
  hashes: UnsafeMutableBufferPointer<BlakeCv>, polynomials: UnsafeMutableBufferPointer<Int32>,
  message: UnsafeMutableRawBufferPointer
) -> W1BootSet? {
  guard policy.debugEmulator, imagePage(policy.machine) != 0, let utc = policy.trustedUTC,
    validPin(systemEnrollment, utc: utc), contract.uuid.count == 16,
    contract.textSHA256.count == 32, !contract.symbol.isEmpty,
    let (kernel, conf) = authorizedKernel(
      archive: archive, signature: signature, enrollment: enrollment,
      policy: policy, hashes: hashes, polynomials: polynomials, message: message, members: 4),
    let p = member(archive, "tessera.init", hashes), let l = member(archive, "LibTessera", hashes),
    p.count <= 8 << 20, l.count <= 8 << 20, kernel.range.count <= 8 << 20,
    !p.overlaps(l), !p.overlaps(conf), !l.overlaps(conf),
    !p.overlaps(kernel.range), !l.overlaps(kernel.range)
  else { return nil }
  func authorize(_ range: Range<Int>, role: EarlyUserRole) -> W1UserMember? {
    let bytes = view(archive, range)
    guard
      let layout = inspectEarlyUserImage(
        bytes, role: role, machine: policy.machine,
        train: policy.train, tir: policy.tir, addressLimit: policy.addressLimit, scratch: hashes),
      authenticatedImage(
        bytes, layout.image, enrollment: systemEnrollment, hashes: hashes,
        polynomials: polynomials, message: message)
    else { return nil }
    return W1UserMember(bytes: bytes, range: range, layout: layout)
  }
  guard let process = authorize(p, role: .initialProcess(entryTag: initEntryTag)),
    let library = authorize(l, role: .systemLibrary),
    let binding = inspectEarlyRIDLBinding(
      executable: process.bytes, framework: library.bytes,
      machine: policy.machine, addressLimit: policy.addressLimit, scratch: hashes,
      contract: contract)
  else { return nil }
  return W1BootSet(
    machine: policy.machine, kernel: kernel, process: process, library: library, binding: binding,
    archiveSHA256: measurementDigest(archive), configurationSHA256: measurementDigest(view(archive, conf)),
    initSHA256: measurementDigest(process.bytes))
}
