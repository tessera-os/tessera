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

public struct W1SystemRootBootSet {
  public let bootSet: W1BootSet
  /// Expected digest of the nonempty TRFS metadata head, not proof of disk contents.
  public let metadataHeadSHA256: InlineArray<32, UInt8>
}

private enum UserArchiveProfile: UInt32 {
  case stage1 = 4, systemRoot = 5
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
  verifyUserArchive(
    archive: archive, signature: signature, enrollment: enrollment,
    systemEnrollment: systemEnrollment, policy: policy, initEntryTag: initEntryTag,
    contract: contract, hashes: hashes, polynomials: polynomials, message: message,
    profile: .stage1)?.bootSet
}

/// Opt in only for a slot requiring a measured, read-only system mount.
/// The caller must verify the actual metadata head against the returned bytes.
public func authorizeQEMUSystemRoot(
  archive: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer,
  enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer, policy: W0Policy,
  contract: EarlyRIDLContract,
  hashes: UnsafeMutableBufferPointer<BlakeCv>, polynomials: UnsafeMutableBufferPointer<Int32>,
  message: UnsafeMutableRawBufferPointer
) -> W1SystemRootBootSet? {
  guard contract.isW1ProcessCurrent,
    let (set, config) = verifyUserArchive(
      archive: archive, signature: signature, enrollment: enrollment,
      systemEnrollment: systemEnrollment, policy: policy, initEntryTag: 0x4d3e_7643,
      contract: contract, hashes: hashes, polynomials: polynomials, message: message,
      profile: .systemRoot),
    let root = member(archive, "system.trfs.root", hashes), root.count == 32,
    !root.overlaps(config), !root.overlaps(set.kernel.range),
    !root.overlaps(set.process.range), !root.overlaps(set.library.range)
  else { return nil }
  let bytes = view(archive, root)
  var value = InlineArray<32, UInt8>(repeating: 0)
  var nonzero: UInt8 = 0
  for i in 0..<32 {
    value[i] = bytes[i]
    nonzero |= bytes[i]
  }
  guard nonzero != 0 else { return nil }
  return W1SystemRootBootSet(bootSet: set, metadataHeadSHA256: value)
}

private func verifyUserArchive(
  archive: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer,
  enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer, policy: W0Policy,
  initEntryTag: UInt32, contract: EarlyRIDLContract,
  hashes: UnsafeMutableBufferPointer<BlakeCv>, polynomials: UnsafeMutableBufferPointer<Int32>,
  message: UnsafeMutableRawBufferPointer, profile: UserArchiveProfile
) -> (bootSet: W1BootSet, configuration: Range<Int>)? {
  guard policy.debugEmulator, imagePage(policy.machine) != 0, let utc = policy.trustedUTC,
    validPin(systemEnrollment, utc: utc), contract.uuid.count == 16,
    contract.textSHA256.count == 32, !contract.symbol.isEmpty,
    let (kernel, conf) = authorizedKernel(
      archive: archive, signature: signature, enrollment: enrollment,
      policy: policy, hashes: hashes, polynomials: polynomials, message: message,
      members: profile.rawValue),
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
  let set = W1BootSet(
    machine: policy.machine, kernel: kernel, process: process, library: library, binding: binding,
    archiveSHA256: measurementDigest(archive), configurationSHA256: measurementDigest(view(archive, conf)),
    initSHA256: measurementDigest(process.bytes))
  return (set, conf)
}
