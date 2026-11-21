import Foundation
import TarwinLoader
import TarwinW0Verify
import XCTest

final class HybridSignatureTests: XCTestCase {
  func testPinnedHybridSignaturesAndMalformedInputs() throws {
    let root = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("SignedAArch64")
    let archive = try Data(contentsOf: root.appendingPathComponent("BOOT.TIR"))
    let pin = try Data(contentsOf: root.appendingPathComponent("test-enrollment.pub"))
    var hashes = [BlakeCv](repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0,
      w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    let digest = try XCTUnwrap(archive.withUnsafeBytes { bytes in
      hashes.withUnsafeMutableBufferPointer { bootSetDigest(bytes, scratch: $0) }
    })
    var message = Data("Tarwin boot set v1\0".utf8)
    for word in [digest.w0, digest.w1, digest.w2, digest.w3, digest.w4, digest.w5, digest.w6, digest.w7] {
      withUnsafeBytes(of: word.littleEndian) { message.append(contentsOf: $0) }
    }
    let envelope = try Data(contentsOf: root.appendingPathComponent("BOOT.SIG"))
    var work = [Int32](repeating: 0, count: 2048)
    func verify(_ message: Data, _ envelope: Data, _ key: Data, workspace: Int = 2048) -> Bool {
      message.withUnsafeBytes { msg in envelope.withUnsafeBytes { sig in
        key.withUnsafeBytes { keys in work.withUnsafeMutableBufferPointer {
          verifyHybridSignature(message: msg, envelope: sig,
            ed25519Key: .init(rebasing: keys[52..<84]),
            mldsa65Key: .init(rebasing: keys[84..<2036]),
            work: .init(start: $0.baseAddress, count: workspace))
        } }
      } }
    }
    XCTAssertTrue(verify(message, envelope, pin))
    XCTAssertFalse(verify(Data(), Data(), pin))
    XCTAssertFalse(verify(message, envelope, pin, workspace: 0))
    var changed = message; changed[0] ^= 1
    XCTAssertFalse(verify(changed, envelope, pin))
    var wrongKey = pin; wrongKey[84] ^= 1
    XCTAssertFalse(verify(message, envelope, wrongKey))
    var changedSignature = envelope; changedSignature[changedSignature.count - 1] ^= 1
    XCTAssertFalse(verify(message, changedSignature, pin))
  }
}
