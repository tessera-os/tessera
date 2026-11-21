import Tarboot
import TarwinBoot
import TarwinLoader
import TarwinW0Verify

public enum QEMUW1Evidence {
  public static let fileName: StaticString = "opt/org.tessera/tarwin/w1.sig"
  public static let scratchSize = 54 * MemoryLayout<BlakeCv>.stride + 8192 + 1024

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
    let out = UnsafeRawBufferPointer(storage), work = UnsafeRawBufferPointer(scratch)
    func protected(_ input: UnsafeRawBufferPointer) -> Bool {
      apart(out, input) && apart(work, input)
    }
    func independent(_ input: UnsafeRawBufferPointer) -> Bool {
      protected(input) && apart(archive, input) && apart(block, input) && apart(map, input)
    }
    guard scratch.count >= Self.scratchSize, let p = scratch.baseAddress, UInt(bitPattern: p) & 15 == 0,
      apart(work, out), protected(block), protected(map), protected(archive),
      independent(enrollment), independent(systemEnrollment), independent(contract.uuid),
      independent(contract.symbol), independent(contract.textSHA256),
      let info = readHandoff(block: block, at: blockAddress, map: map, at: mapAddress),
      info.security & 2 != 0, info.bootSet == archiveAddress,
      info.bootSetSize == UInt64(archive.count),
      let envelope = copyQEMUFile(&reader, named: fileName, sizes: 1...65536, into: storage)
    else { return nil }
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
