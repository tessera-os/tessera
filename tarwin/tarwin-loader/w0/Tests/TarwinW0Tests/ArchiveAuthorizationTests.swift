import Foundation
import TarwinLoader
import TarwinW0Verify
import XCTest

final class ArchiveAuthorizationTests: XCTestCase {
  func testRecordedAuthorization() throws {
    let root = try XCTUnwrap(Bundle.module.resourceURL)
    let key = try Data(contentsOf: root.appendingPathComponent("SignedAArch64/test-enrollment.pub"))
    for (fixture, machine, entry, accepted): (String, UInt16, UInt64, Bool) in [
      ("SignedAArch64/BOOT", 183, 0x4010, true), ("SignedX64/BOOT", 62, 0x1010, true),
      ("SignedAArch64/untagged", 183, 0x4000, false),
    ] {
      try checkArchive(
        archive: Data(contentsOf: root.appendingPathComponent(fixture + ".TIR")),
        signature: Data(contentsOf: root.appendingPathComponent(fixture + ".SIG")),
        key: key, clock: 1_795_237_613, target: machine, entry: entry, accepted: accepted)
    }
  }

  func testExternalStage0Archive() throws {
    let e = ProcessInfo.processInfo.environment
    guard e.keys.contains(where: { $0.hasPrefix("W0_TEST_") }) else {
      throw XCTSkip("no external W0 archive requested")
    }
    func data(_ name: String) throws -> Data {
      try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(e["W0_TEST_" + name])))
    }
    let targets: [String: UInt16] = ["aarch64": 183, "x64": 62, "rv64": 243]
    try checkArchive(
      archive: data("ARCHIVE"), signature: data("SIGNATURE"), key: data("ENROLLMENT"),
      clock: XCTUnwrap(UInt64(e["W0_TEST_UTC"] ?? "")),
      target: XCTUnwrap(targets[e["W0_TEST_MACHINE"] ?? "aarch64"]),
      entry: XCTUnwrap(UInt64(e["W0_TEST_ENTRY_HEX"] ?? "4010", radix: 16)))
  }

  private func checkArchive(
    archive: Data, signature: Data, key: Data,
    clock: UInt64, target: UInt16, entry: UInt64, accepted: Bool = true
  ) throws {
    guard key.count == 2036, signature.count > 3373, archive.count > 24 else {
      return XCTFail("incomplete fixture")
    }
    var hashes = Array(
      repeating: BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    var work = [Int32](repeating: 0, count: 2048)
    var msg = [UInt8](repeating: 0, count: 1024)
    func run(
      _ a: Data, _ s: Data, _ k: Data, machine: UInt16 = target, time: UInt64? = clock,
      floor: UInt64? = 1, slot: UInt8 = 0, debug: Bool = true, cpu: Bool = true,
      tir: W0Version = (26, 11, 2)
    ) -> Bool {
      let p = W0Policy(
        machine: machine, baselineSupported: cpu, trustedUTC: time, train: (26, 11, 1), tir: tir,
        addressLimit: 1 << 32, securityFloor: floor, slot: slot, debugEmulator: debug)
      return a.withUnsafeBytes { aa in
        s.withUnsafeBytes { ss in
          k.withUnsafeBytes { kk in
            hashes.withUnsafeMutableBufferPointer { h in
              work.withUnsafeMutableBufferPointer { w in
                msg.withUnsafeMutableBytes { m in
                  guard
                    let result = authorizeQEMUStage0(
                      archive: aa, signature: ss, enrollment: kk, policy: p, hashes: h,
                      polynomials: w, message: m)
                  else { return false }
                  XCTAssertEqual(
                    result.bytes.baseAddress, aa.baseAddress! + result.range.lowerBound)
                  XCTAssertEqual(result.bytes.count, result.range.count)
                  XCTAssertEqual(result.image.entry, entry)
                  XCTAssertEqual(result.securityVersion, 1)
                  do { try checkExecutablePages(result, machine: machine) } catch {
                    XCTFail("page verification: \(error)")
                  }
                  return true
                }
              }
            }
          }
        }
      }
    }
    XCTAssertEqual(run(archive, signature, key), accepted)
    guard accepted else { return }
    for i in [8, signature.count - 3373, signature.count - 3309] {
      var bad = signature
      bad[i] ^= 1
      XCTAssertFalse(run(archive, bad, key))
    }
    for i in [20, 52, 84] {
      var bad = key
      bad[i] ^= 1
      XCTAssertFalse(run(archive, signature, bad))
    }
    var bad = archive
    bad[24] ^= 1
    XCTAssertFalse(run(bad, signature, key))
    XCTAssertFalse(run(archive, signature, key, machine: target == 62 ? 183 : 62))
    XCTAssertFalse(run(archive, signature, key, time: nil))
    XCTAssertFalse(run(archive, signature, key, time: .max))
    XCTAssertFalse(run(archive, signature, key, floor: nil))
    XCTAssertFalse(run(archive, signature, key, floor: 2))
    XCTAssertFalse(run(archive, signature, key, slot: 1))
    XCTAssertFalse(run(archive, signature, key, debug: false))
    XCTAssertFalse(run(archive, signature, key, cpu: false))
    XCTAssertFalse(run(archive, signature, key, tir: (26, 11, 3)))
  }
}
