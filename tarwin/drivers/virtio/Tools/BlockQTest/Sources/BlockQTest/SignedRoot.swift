import CryptoKit
import Foundation
import TarwinLoader
import TarwinW0Verify

// Host regression fixture only. Never use this historical clock or these test
// enrollments for a live system. The fixture kernel is not executed.
func signedFixtureRoot(archiveDirectory: URL, corpus: URL) throws -> Data {
  func read(_ base: URL, _ name: String) throws -> Data {
    try Data(contentsOf: base.appendingPathComponent(name))
  }
  func pin(_ name: String, _ digest: String) throws -> Data {
    let data = try read(corpus, name)
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest
    else { throw Failure("Unexpected test enrollment: " + name) }
    return data
  }
  let archive = try read(archiveDirectory, "TEST-ONLY.TIR")
  let signature = try read(archiveDirectory, "TEST-ONLY.SIG")
  let boot = try pin("boot.pub", "1588bd67734dcd644d27eee34e4b72799ceb391886c6138b1f950d9e571004cc")
  let system = try pin("system.pub", "2fca0a5bb136950bd925c2e831af054d156b1b0e3cd6b5b53002e5773e9e5fa2")
  let sdk = try read(corpus, "LibTessera.ridlmeta"), receipt = try read(corpus, "sdk.SIG")
  let policy = W0Policy(machine: ElfMachine.aarch64, baselineSupported: true,
    trustedUTC: 1_795_268_738, train: (26, 11, 1), tir: (26, 11, 2),
    addressLimit: 1 << 32, securityFloor: 1, slot: 0, debugEmulator: true)
  var hashes = [BlakeCv](
    repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
  var work = [Int32](repeating: 0, count: 2048), message = Data(repeating: 0, count: 1024)
  let root: Data? = hashes.withUnsafeMutableBufferPointer { h in
    work.withUnsafeMutableBufferPointer { w in message.withUnsafeMutableBytes { m in
      system.withUnsafeBytes { s in sdk.withUnsafeBytes { k in receipt.withUnsafeBytes { r in
        withProvisionedDebugW1SDK(k, receipt: r, systemEnrollment: s, policy: policy,
          hashes: h, polynomials: w, message: m) { contract -> Data? in
          boot.withUnsafeBytes { b in signature.withUnsafeBytes { sig in archive.withUnsafeBytes { a in
            guard let verified = authorizeQEMUSystemRoot(archive: a, signature: sig, enrollment: b,
              systemEnrollment: s, policy: policy, contract: contract,
              hashes: h, polynomials: w, message: m) else { return nil }
            return withUnsafeBytes(of: verified.metadataHeadSHA256) { Data($0) }
          } } }
        } ?? nil
      } } }
    } }
  }
  guard let root else { throw Failure("Signed test boot set or SDK receipt refused") }
  return root
}
