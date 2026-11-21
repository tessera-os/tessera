#if TARBOOT_ENTER_W1_INTAKE
import Tarboot
import TarbootPreflight
import TarwinBoot
import TarwinDevice
import TarwinKernelRandom
import TarwinLoader
import TarwinW0Verify

// The trusted debug launcher supplies this EFI image and its SDK/pins independently
// of the selected archive. This first check is not an image installation permit.
func prepareW1(_ boot: inout FirmwareBootServices, input: borrowing FirmwareBootServices.LoaderPages,
  archive: borrowing FirmwareBootServices.LoaderPages, signature: borrowing FirmwareBootServices.LoaderPages,
  storage: borrowing FirmwareBootServices.LoaderPages) -> (archive: Int, signature: Int)? {
  var name = counterName
  guard let floor = withUnsafeBytes(of: &name, { boot.securityVersionFloor(index: 0x0180_f001, name: $0) }),
    let k = ColdKernelLayout(handoff: storage.base), storage.count == ColdKernelLayout.pages,
    signature.length == 65536, archive.length <= 1 << 20, input.length == archive.length + signature.length,
    let src = UnsafeMutableRawPointer(bitPattern: UInt(input.base)),
    let dst = UnsafeMutableRawPointer(bitPattern: UInt(archive.base)),
    let sig = UnsafeMutableRawPointer(bitPattern: UInt(signature.base)) else { return nil }
  let capacity = Int(archive.length)
  let source = DeviceRange(base: input.base, length: input.length)
  let retained = DeviceRange(base: archive.base, length: archive.length)
  let detached = DeviceRange(base: signature.base, length: signature.length)
  let workspace = DeviceRange(base: storage.base, length: storage.length)
  guard !source.overlaps(retained), !source.overlaps(detached), !retained.overlaps(detached),
    !workspace.overlaps(source), !workspace.overlaps(retained), !workspace.overlaps(detached) else { return nil }
  var path: InlineArray<10, UInt16> = [92,66,79,79,84,46,84,73,82,0]
  guard let n = withUnsafeBytes(of: &path, {
    boot.readBootFile(path: $0.bindMemory(to: UInt16.self), into: .init(start: src, count: capacity))
  }), (1...capacity).contains(n) else { return nil }
  path[6] = 83; path[7] = 73; path[8] = 71
  guard let m = withUnsafeBytes(of: &path, {
    boot.readBootFile(path: $0.bindMemory(to: UInt16.self), into: .init(start: src + capacity, count: 65536))
  }), (1...65536).contains(m) else { return nil }
  let bytes = UnsafeRawBufferPointer(start: src, count: n)
  let envelope = UnsafeRawBufferPointer(start: src + capacity, count: m)
  let scratch = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(k.scratch)), count: 16384)
  guard withW1Authority(floor: floor, work: scratch, { policy, pin, system, contract in
    authorizeW1(bytes, envelope, policy, pin, system, contract, scratch) != nil
  }) == true else { return nil }
  guard let cfg = configurationBytes(bytes), boot.measureBootSet(bytes, configuration: cfg) else { return nil }
  dst.copyMemory(from: src, byteCount: n)
  sig.copyMemory(from: src + capacity, byteCount: m)
  return (n, m)
}

private func configurationBytes(_ bytes: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
  var digest = DigestScratch()
  let name: StaticString = "boot.json"
  guard case .intact(let range) = inspectRawMember(bytes,
    path: .init(start: name.utf8Start, count: name.utf8CodeUnitCount), scratch: &digest) else { return nil }
  return .init(rebasing: bytes[range])
}

private func authorizeW1(_ bytes: UnsafeRawBufferPointer, _ envelope: UnsafeRawBufferPointer,
  _ policy: W0Policy, _ pin: UnsafeRawBufferPointer, _ system: UnsafeRawBufferPointer,
  _ contract: EarlyRIDLContract, _ scratch: UnsafeMutableRawBufferPointer) -> W1BootSet? {
  let h = 54 * MemoryLayout<BlakeCv>.stride
  return authorizeQEMUStage1(archive: bytes, signature: envelope, enrollment: pin, systemEnrollment: system,
    policy: policy, contract: contract, hashes: UnsafeMutableRawBufferPointer(rebasing: scratch[..<h]).bindMemory(to: BlakeCv.self),
    polynomials: UnsafeMutableRawBufferPointer(rebasing: scratch[h..<h+8192]).bindMemory(to: Int32.self),
    message: .init(rebasing: scratch[h+8192..<h+8192+1024]))
}

func fenceBeforeW1(_ fence: borrowing FirmwareBootServices.ColdWorkspace, layout k: ColdKernelLayout,
  archive: borrowing FirmwareBootServices.LoaderPages, signature: borrowing FirmwareBootServices.LoaderPages,
  image: borrowing FirmwareBootServices.LoaderPages,
  stack: borrowing FirmwareBootServices.LoaderPages, log: borrowing FirmwareBootServices.LoaderPages,
  regions: UnsafeBufferPointer<FirmwareRegion>) -> Bool {
  guard fence.table == k.table else { return false }
  var ranges: InlineArray<7, DeviceRange> = [
    .init(base: k.handoff, length: k.table - k.handoff), .init(base: k.signature, length: k.end - k.signature),
    .init(base: archive.base, length: archive.length), .init(base: image.base, length: image.length),
    .init(base: stack.base, length: stack.length), .init(base: log.base, length: log.length),
    .init(base: signature.base, length: signature.length),
  ]
  var bus = ColdBus(layout: .lowOnly)
  return withUnsafeBytes(of: &ranges) {
    let held = $0.bindMemory(to: DeviceRange.self)
    for i in 0..<held.count {
      let extent = held[i]
      var owned = false
      for j in 0..<regions.count {
        if regions[j].holdsLoaderData(base: extent.base, length: extent.length) { owned = true; break }
      }
      guard owned else { return false }
      for j in 0..<i where extent.overlaps(held[j]) { return false }
    }
    return denyVirtBootDMA(table: k.table, commands: k.commands, protected: held,
      layout: .lowOnly, bus: &bus) == .streamsDenied
  }
}

// This check uses only the post-exit, fenced bytes. The signed kernel
// repeats it on entry; a firmware result is not a capability to start init.
func transferW1(handoff: UInt64, image: borrowing FirmwareBootServices.LoaderPages,
  stack: borrowing FirmwareBootServices.LoaderPages, archive: borrowing FirmwareBootServices.LoaderPages,
  size: Int, signature: borrowing FirmwareBootServices.LoaderPages, signatureBytes: Int,
  log: borrowing FirmwareBootServices.LoaderPages, logBytes: Int) -> Bool {
  guard let intake = W1ColdKernelIntake(handoff: handoff), size > 0, size <= archive.length,
    (1...65536).contains(signatureBytes), signatureBytes <= signature.length, logBytes > 0, logBytes <= log.length,
    intake.layout.containsSeparateArchive(archive.base, bytes: UInt64(size)) else { return false }
  let frozen = UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: UInt(archive.base)), count: size)
  let envelope = UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: UInt(signature.base)), count: signatureBytes)
  let events = UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: UInt(log.base)), count: logBytes)
  var command = InlineArray<1100, UInt8>(repeating: 0)
  var sample = InlineArray<32, UInt8>(repeating: 0)
  let kernel: W0Kernel? = withUnsafeMutableBytes(of: &command) { bytes in
    guard var port = TPMFIFO(registers: W1VirtTPM(), scratch: bytes, pollLimit: 500000),
      readTPMEntropy32(&port, into: &sample) else { return nil }
    let launch = withUnsafeBytes(of: &sample) { fresh in
      FixedDebugRandomLaunch(policy: .debugQEMU, allowsMigration: false, allowsSnapshots: false,
        block: intake.block, at: handoff, map: intake.map, at: handoff + 4096,
        hardware: fresh, source: .emulatedTPM)
    }
    sample = .init(repeating: 0)
    guard let launch, let profile = W1HandoffProfile(nonRestorable: launch),
      let b = profile.decode(intake.block, at: handoff, map: intake.map, at: handoff + 4096),
      b.security == 2, b.slot == 0, b.bootSet == archive.base, b.bootSetSize == size,
      b.logAddress == log.base, b.logSize == logBytes else { return nil }
    var cfg = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
    let pio = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(intake.layout.signature)), count: 65536)
    guard let second = copyQEMUFile(&cfg, named: QEMUW1Evidence.fileName, sizes: 1...65536, into: pio),
      second.count == signatureBytes else { return nil }
    for i in 0..<signatureBytes where pio[i] != envelope[i] { return nil }
    let work = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(intake.layout.scratch)), count: 16384)
    guard let config = configurationBytes(frozen), let archiveDigest = firmwareMeasurementSHA256(frozen),
      let configDigest = firmwareMeasurementSHA256(config),
      let replay = replayColdFirmwarePCRs(events, archive: archiveDigest,
        configuration: configDigest, dedicatedBanks: true),
      matchesFirmwarePCRs(&port, archive: replay.archive, configuration: replay.configuration)
    else { _ = reportFixedMarker("TARBOOT-W1-REFUSED-MEASUREMENT\r\n"); return nil }
    guard let verified = withW1Authority(port: &port, work: work, { policy, boot, system, contract in
      authorizeW1(frozen, envelope, policy, boot, system, contract, work)
    }) ?? nil else { return nil }
    for i in 0..<32 {
      guard verified.archiveSHA256[i] == archiveDigest[i],
        verified.configurationSHA256[i] == configDigest[i] else { return nil }
    }
    return verified.kernel
  }
  guard let kernel, reportFixedMarker("TARBOOT-W1-FROZEN-COPY-CONFIRMED\r\n") else { return false }
  #if TARBOOT_TEST_W1_GATE_ONLY
    while true {}
  #else
  guard let entry = installArmKernel(kernel, in: image) else { return false }
  cleanRange(image.base, image.base + image.length)
  cleanRange(handoff, intake.layout.end)
  cleanRange(stack.base, stack.base + stack.length)
  cleanRange(archive.base, archive.base + archive.length)
  cleanRange(log.base, log.base + log.length)
  guard reportFixedMarker("TARBOOT-W1-VERIFIED-TRANSFER\r\n") else { return false }
  enterArm(handoff, entry, stack.base + stack.length)
  while true {}
  #endif
}
#endif
