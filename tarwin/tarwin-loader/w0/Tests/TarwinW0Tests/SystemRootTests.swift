import CryptoKit
import Foundation
import TarwinLoader
import XCTest

@testable import TarwinW0Verify

final class SystemRootTests: XCTestCase {
  func testSignedSystemRootProfile() throws {
    let dir = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("SystemRootCorpus")
    func read(_ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }
    let ordinary = try read("ordinary.TIR")
    let boot = try read("boot.pub"), system = try read("system.pub")
    let sdk = try read("LibTessera.ridlmeta"), receipt = try read("sdk.SIG")
    var hashes = [BlakeCv](
      repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    var work = [Int32](repeating: 0, count: 2048), msg = [UInt8](repeating: 0, count: 1024)
    func policy(debug: Bool) -> W0Policy {
      W0Policy(machine: ElfMachine.aarch64, baselineSupported: true, trustedUTC: 1_795_268_738,
        train: (26, 11, 1), tir: (26, 11, 2), addressLimit: 1 << 32, securityFloor: 1, slot: 0,
        debugEmulator: debug)
    }
    try boot.withUnsafeBytes { b in try system.withUnsafeBytes { s in
      try sdk.withUnsafeBytes { k in try receipt.withUnsafeBytes { r in
        try hashes.withUnsafeMutableBufferPointer { h in try work.withUnsafeMutableBufferPointer { w in
          try msg.withUnsafeMutableBytes { m in
            // Keep file IO outside the nonthrowing receipt callback.
            let cases = try RootFixture.allCases.map { ($0, try read($0.rawValue + ".SIG")) }
            let ordinarySignature = try read("ordinary.SIG")
            let ran = withProvisionedDebugW1SDK(k, receipt: r, systemEnrollment: s,
              policy: policy(debug: true), hashes: h, polynomials: w, message: m) { contract in
              func check(_ bytes: Data, _ sidecar: Data, ordinaryOK: Bool = false,
                rootOK: Bool = false, signed: Bool = true, debug: Bool = true,
                file: StaticString = #filePath, line: UInt = #line) {
                bytes.withUnsafeBytes { a in sidecar.withUnsafeBytes { sig in
                  // A refused malformed manifest must still have a valid detached signature.
                  let cv = bootSetDigest(a, scratch: h)!
                  var domain = Data("Tarwin boot set v1\0".utf8)
                  for word in [cv.w0, cv.w1, cv.w2, cv.w3, cv.w4, cv.w5, cv.w6, cv.w7] {
                    withUnsafeBytes(of: word.littleEndian) { domain.append(contentsOf: $0) }
                  }
                  XCTAssertEqual(domain.withUnsafeBytes { authenticated(sig, b, $0, h, w) },
                    signed, file: file, line: line)
                  let p = policy(debug: debug)
                  let verified = authorizeQEMUSystemRoot(archive: a, signature: sig, enrollment: b,
                    systemEnrollment: s, policy: p, contract: contract, hashes: h,
                    polynomials: w, message: m)
                  XCTAssertEqual(verified != nil, rootOK, file: file, line: line)
                  if let verified {
                    XCTAssertEqual(withUnsafeBytes(of: verified.metadataHeadSHA256) { Data($0) },
                      RootFixture.headSHA256)
                    XCTAssertEqual(withUnsafeBytes(of: verified.bootSet.archiveSHA256) { Data($0) },
                      Data(SHA256.hash(data: bytes)))
                    XCTAssertEqual(verified.bootSet.process.bytes.baseAddress,
                      a.baseAddress! + verified.bootSet.process.range.lowerBound)
                  }
                  XCTAssertEqual(authorizeQEMUStage1(archive: a, signature: sig, enrollment: b,
                    systemEnrollment: s, policy: p, contract: contract, hashes: h,
                    polynomials: w, message: m) != nil, ordinaryOK, file: file, line: line)
                  XCTAssertNil(authorizeQEMUStage0(archive: a, signature: sig, enrollment: b,
                    policy: p, hashes: h, polynomials: w, message: m), file: file, line: line)
                } }
              }
              check(ordinary, ordinarySignature, ordinaryOK: true)
              for (fixture, sig) in cases {
                let a = fixture.archive(from: ordinary)
                check(a, sig, rootOK: fixture == .valid || fixture == .platformBuilder)
                if fixture == .platformBuilder {
                  XCTAssertEqual(SHA256.hash(data: a).map { String(format: "%02x", $0) }.joined(),
                    "0b4a670a09d7c5d984b8c9ea39b1d9f0d7cb2b4076b2f53f9ed0874df5028fbd")
                  let other = cases.first { $0.0 == .valid }!.1
                  check(a, other, signed: false)
                  check(RootFixture.valid.archive(from: ordinary), sig, signed: false)
                }
                if fixture == .valid {
                  check(a, sig, debug: false)
                  var damaged = a
                  let at = damaged.range(of: RootFixture.headSHA256)!.lowerBound
                  damaged[at] ^= 1
                  check(damaged, sig, signed: false)
                }
              }
              return true
            }
            XCTAssertEqual(ran, true)
          }
        } }
      } }
    } }
  }
}
