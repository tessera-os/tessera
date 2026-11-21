import Foundation
import TarwinLoader
import TarwinW0Verify
import XCTest

final class ArchiveAuthorizationTests: XCTestCase {
  // Integration with an independently generated, exact signed W0 release set.
  // No keys, trust pins or fake "signature passed" callbacks in the test binary.
  func testExactSignedStage0Archive() throws {
    let e = ProcessInfo.processInfo.environment
    guard let a = e["W0_TEST_ARCHIVE"], let s = e["W0_TEST_SIGNATURE"],
      let k = e["W0_TEST_ENROLLMENT"],
      let clock = UInt64(e["W0_TEST_UTC"] ?? "")
    else { throw XCTSkip("supply the signed W0 fixture and trusted test time") }
    let archive = try Data(contentsOf: URL(fileURLWithPath: a))
    let signature = try Data(contentsOf: URL(fileURLWithPath: s))
    let key = try Data(contentsOf: URL(fileURLWithPath: k))
    var hashes = Array(
      repeating: BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    var work = [Int32](repeating: 0, count: 2048)
    var msg = [UInt8](repeating: 0, count: 1024)
    func run(
      _ a: Data, _ s: Data, _ k: Data, machine: UInt16 = 183, time: UInt64? = clock,
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
                  XCTAssertEqual(result.image.entry, 0x4000)
                  XCTAssertEqual(result.securityVersion, 1)
                  return true
                }
              }
            }
          }
        }
      }
    }
    XCTAssertTrue(run(archive, signature, key))
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
    XCTAssertFalse(run(archive, signature, key, machine: 62))
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
