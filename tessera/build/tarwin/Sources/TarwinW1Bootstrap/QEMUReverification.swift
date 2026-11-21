import Tarboot
import TarwinBoot
import TarwinLoader
import TarwinW0Verify

public enum QEMUW1Evidence {
  public static let fileName: StaticString = "opt/org.tessera/tarwin/w1.sig"
  public static let scratchSize = 54 * MemoryLayout<BlakeCv>.stride + 8192 + 1024

  #if arch(arm64)
    /// Before ExitBootServices retrieve only the detached TSG1 from the EFI
    /// image's own volume. All trust inputs come from the authenticated debug
    /// installation; the caller protects and pins the archive and writable
    /// buffers exactly as for verify(). Only the kernel member is returned:
    /// this firmware verdict does not authorize a process after handoff.
    @unsafe public static func firmwareKernel(
      archive: UnsafeRawBufferPointer, services: borrowing FirmwareBootServices,
      into storage: UnsafeMutableRawBufferPointer,
      enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer,
      policy: W0Policy, contract: EarlyRIDLContract, scratch: UnsafeMutableRawBufferPointer
    ) -> W0Kernel? {
      var path: InlineArray<10, UInt16> = [92, 66, 79, 79, 84, 46, 83, 73, 71, 0]
      return verifyArchive(archive, into: storage, enrollment: enrollment,
        systemEnrollment: systemEnrollment, policy: policy, contract: contract, scratch: scratch
      ) { dest in
        withUnsafeBytes(of: &path) {
          services.readBootFile(path: $0.bindMemory(to: UInt16.self), into: dest)
        }
      }?.kernel
    }
  #endif

  /// Caller pins the mapped physical extents, excludes DMA and physical
  /// aliases, and holds the exact archive immutable through placement. A
  /// type-7 descriptor alone does not guarantee those properties. Serialize
  /// fw_cfg and obtain the policy, both pins and SDK independently of it,
  /// the archive and the ESP. Only the hybrid verifier authorizes a set.
  @unsafe public static func verify<R: QEMUFileReader>(
    block: UnsafeRawBufferPointer, at blockAddress: UInt64,
    map: UnsafeRawBufferPointer, at mapAddress: UInt64,
    archive: UnsafeRawBufferPointer, at archiveAddress: UInt64,
    reader: inout R, into storage: UnsafeMutableRawBufferPointer,
    enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer,
    policy: W0Policy, contract: EarlyRIDLContract, scratch: UnsafeMutableRawBufferPointer
  ) -> W1BootSet? {
    func outsideHandoff(_ input: UnsafeRawBufferPointer) -> Bool {
      apart(block, input) && apart(map, input)
    }
    guard outsideHandoff(.init(storage)), outsideHandoff(.init(scratch)), outsideHandoff(archive),
      outsideHandoff(enrollment), outsideHandoff(systemEnrollment), outsideHandoff(contract.uuid),
      outsideHandoff(contract.symbol), outsideHandoff(contract.textSHA256),
      let info = readHandoff(block: block, at: blockAddress, map: map, at: mapAddress),
      info.security & 2 != 0, info.bootSet == archiveAddress,
      info.bootSetSize == UInt64(archive.count)
    else { return nil }
    return verifyArchive(archive, into: storage, enrollment: enrollment,
      systemEnrollment: systemEnrollment, policy: policy, contract: contract, scratch: scratch
    ) { copyQEMUFile(&reader, named: fileName, sizes: 1...65536, into: $0)?.count }
  }

  private static func verifyArchive(
    _ archive: UnsafeRawBufferPointer, into storage: UnsafeMutableRawBufferPointer,
    enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer,
    policy: W0Policy, contract: EarlyRIDLContract, scratch: UnsafeMutableRawBufferPointer,
    readSignature: (UnsafeMutableRawBufferPointer) -> Int?
  ) -> W1BootSet? {
    let out = UnsafeRawBufferPointer(storage), work = UnsafeRawBufferPointer(scratch)
    func independent(_ input: UnsafeRawBufferPointer) -> Bool {
      apart(out, input) && apart(work, input) && apart(archive, input)
    }
    guard scratch.count >= Self.scratchSize, let p = scratch.baseAddress, UInt(bitPattern: p) & 15 == 0,
      apart(work, out), apart(work, archive), apart(out, archive),
      independent(enrollment), independent(systemEnrollment), independent(contract.uuid),
      independent(contract.symbol), independent(contract.textSHA256),
      let n = readSignature(.init(rebasing: storage.prefix(65536))),
      (1...65536).contains(n), n <= out.count
    else { return nil }
    let envelope = UnsafeRawBufferPointer(rebasing: out[..<n])
    let poly = 54 * MemoryLayout<BlakeCv>.stride
    return authorizeQEMUStage1(
      archive: archive, signature: envelope, enrollment: enrollment, systemEnrollment: systemEnrollment,
      policy: policy, contract: contract,
      hashes: UnsafeMutableRawBufferPointer(rebasing: scratch[..<poly]).bindMemory(to: BlakeCv.self),
      polynomials: UnsafeMutableRawBufferPointer(rebasing: scratch[poly..<poly + 8192]).bindMemory(to: Int32.self),
      message: .init(rebasing: scratch[poly + 8192..<Self.scratchSize]))
  }
}

private func apart(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
  if a.isEmpty || b.isEmpty { return true }
  let x = UInt(bitPattern: a.baseAddress), y = UInt(bitPattern: b.baseAddress)
  return x <= y ? UInt(a.count) <= y - x : UInt(b.count) <= x - y
}
