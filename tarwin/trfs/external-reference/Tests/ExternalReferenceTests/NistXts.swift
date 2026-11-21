import CryptoKit
import Foundation
import XCTest

@testable import TRFS

/// NIST CAVP XTSGenAES256, "data unit seq no" tweak format: the 128-bit
/// little-endian tweak TRFS.md fixes for its sector index.
struct NistCase {
  let encrypt: Bool, bits: Int, key: [UInt8], unit: UInt64, pt: [UInt8], ct: [UInt8]
}
let nistCases: [NistCase] = {
  let path = packageRoot.appendingPathComponent("vectors/XTSGenAES256-DataUnitSeqNo.rsp").path
  let text = try! String(contentsOfFile: path, encoding: .utf8)
  var section = "", fields = [String: String](), out = [NistCase]()
  func flush() {
    guard let k = fields["Key"], let n = fields["DataUnitSeqNumber"], let l = fields["DataUnitLen"]
    else { return }
    out.append(
      .init(
        encrypt: section == "ENCRYPT", bits: Int(l)!, key: bytes(hex: k), unit: UInt64(n)!,
        pt: bytes(hex: fields["PT"]!), ct: bytes(hex: fields["CT"]!)))
  }
  for raw in text.split(whereSeparator: \.isNewline) {
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if line == "[ENCRYPT]" || line == "[DECRYPT]" {
      flush()
      fields = [:]
      section = String(line.dropFirst().dropLast())
    } else if let r = line.range(of: " = ") {
      let k = String(line[..<r.lowerBound])
      if k == "COUNT" {
        flush()
        fields = [:]
      }
      fields[k] = String(line[r.upperBound...])
    }
  }
  flush()
  return out
}()

final class NistXtsTests: XCTestCase {
  func testVectorFileIsTheRecordedNistOriginal() throws {
    let url = packageRoot.appendingPathComponent("vectors/XTSGenAES256-DataUnitSeqNo.rsp")
    XCTAssertEqual(hex(SHA256.hash(data: try Data(contentsOf: url))),
      "8b72c26e9a9405524e4139bba36619fff80e1ef3ef1f317bf36f5e968a133fd1")
    XCTAssertEqual(nistCases.count, 1000)
    XCTAssertEqual(nistCases.filter { $0.bits % 128 == 0 }.count, 600)
  }

  func testXtsSectorReproducesEveryWholeBlockNistVector() {
    var checked = 0
    for c in nistCases where c.bits % 128 == 0 {
      XCTAssertEqual(xtsSector(c.pt, key: c.key, tweak: c.unit, decrypt: false), c.ct)
      XCTAssertEqual(xtsSector(c.ct, key: c.key, tweak: c.unit, decrypt: true), c.pt)
      checked += 1
    }
    XCTAssertEqual(checked, 600)
  }

  func testWrongTweakKeyOrderOrCiphertextNeverReproducesTheVector() {
    for c in nistCases where c.bits % 128 == 0 {
      let swapped = Array(c.key[32...] + c.key[..<32])
      XCTAssertNotEqual(xtsSector(c.pt, key: c.key, tweak: c.unit + 1, decrypt: false), c.ct)
      if c.unit.byteSwapped != c.unit {
        XCTAssertNotEqual(
          xtsSector(c.pt, key: c.key, tweak: c.unit.byteSwapped, decrypt: false), c.ct)
      }
      XCTAssertNotEqual(xtsSector(c.pt, key: swapped, tweak: c.unit, decrypt: false), c.ct)
      var bad = c.ct
      bad[bad.count - 1] ^= 1
      let pt = xtsSector(bad, key: c.key, tweak: c.unit, decrypt: true)!
      XCTAssertNotEqual(Array(pt.suffix(16)), Array(c.pt.suffix(16)))
      XCTAssertEqual(Array(pt.prefix(c.pt.count - 16)), Array(c.pt.prefix(c.pt.count - 16)))
    }
  }

  /// The 400 ciphertext-stealing vectors (140 and 250 bits) are outside
  /// TRFS's 4096-byte data unit; XtsSector refuses partial blocks.
  func testPartialBlockUnitsAreRefused() {
    let m = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 16)
    defer { m.deallocate() }
    XCTAssertEqual(nistCases.filter { $0.bits % 128 != 0 }.count, 400)
    for n in [15, 18, 31, 33] {
      XCTAssertNil(SectorPin(physical: 0x1000, bytes: .init(rebasing: m[..<n])))
    }
  }

  func testExternalImplementationsAgreeWithNist() throws {
    let ref = try Reference()
    let out = try ref.run(["nist", packageRoot.appendingPathComponent("vectors/XTSGenAES256-DataUnitSeqNo.rsp").path])
    let r = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: [String: Int]]
    XCTAssertEqual(r["pyca"]?["passed"], 600)
    XCTAssertEqual(r["libressl"]?["passed"], 600)
    print("external references:", try ref.run(["version"]), out)
  }
}
