import XCTest

@testable import TarwinW0Verify

private func bytes(_ hex: String) -> [UInt8] {
  stride(from: 0, to: hex.count, by: 2).map {
    let a = hex.index(hex.startIndex, offsetBy: $0)
    return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)!
  }
}
final class SignatureTests: XCTestCase {
  func testShakeEmpty() {
    var s = Shake(256)
    s.finish()
    XCTAssertEqual(
      (0..<32).map { _ in s.byte() },
      bytes("46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762f"))
  }
  func testACVPSigVerFIPS204Group3Case43() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "acvp-43", withExtension: "json"))
    let fields = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    func field(_ name: String) throws -> Data {
      try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fields[name])))
    }
    let pk = try field("pk")
    let msg = try field("message")
    let ctx = try field("context")
    let sig = try field("signature")
    var scratch = [Int32](repeating: 0, count: 2048)
    func verify(_ s: Data, _ context: Data) -> Bool {
      pk.withUnsafeBytes { k in
        msg.withUnsafeBytes { m in
          s.withUnsafeBytes { ss in
            context.withUnsafeBytes { cc in
              scratch.withUnsafeMutableBufferPointer {
                verifyMLDSA65(key: k, message: m, context: cc, signature: ss, work: $0)
              }
            }
          }
        }
      }
    }
    XCTAssertTrue(verify(sig, ctx))
    XCTAssertFalse(verify(sig, Data()))
    for p in [0, 48, 3248, 3308] {
      var invalid = sig
      invalid[p] ^= 0xff
      XCTAssertFalse(verify(invalid, ctx))
    }
  }
  func testRFC8032EmptyMessage() {
    let key = bytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
    let sig = bytes(
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
    )
    func verify(_ k: [UInt8], _ s: [UInt8], _ m: [UInt8]) -> Bool {
      k.withUnsafeBytes { key in
        s.withUnsafeBytes { sig in
          m.withUnsafeBytes { verifyEd25519(key: key, message: $0, signature: sig) }
        }
      }
    }
    XCTAssertTrue(verify(key, sig, []))
    XCTAssertFalse(verify(key, sig, [0]))
    var high = sig
    high[63] |= 128
    XCTAssertFalse(verify(key, high, []))
    let identity = [UInt8](arrayLiteral: 1) + [UInt8](repeating: 0, count: 31)
    XCTAssertFalse(verify(identity, identity + [UInt8](repeating: 0, count: 32), []))
  }
}
