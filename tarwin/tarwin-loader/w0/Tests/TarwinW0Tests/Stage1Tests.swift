import CryptoKit
import Foundation
import TarwinLoader
import XCTest

@testable import TarwinW0Verify

final class Stage1Tests: XCTestCase {
  func testBankDigestAgainstSystemSHA256() {
    var old = InlineArray<32, UInt8>(repeating: 0)
    var event = InlineArray<32, UInt8>(repeating: 0)
    for i in 0..<32 {
      old[i] = UInt8(i)
      event[i] = UInt8(63 - i)
    }
    let expected = SHA256.hash(
      data: withUnsafeBytes(of: old) { Data($0) } + withUnsafeBytes(of: event) { Data($0) })
    XCTAssertEqual(
      withUnsafeBytes(of: replaySHA256PCR(previous: old, event: event)) { Data($0) }, Data(expected)
    )
    for length in [0, 1, 55, 56, 63, 64, 65, 111, 119, 120, 127, 128, 16385] {
      let bytes = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
      let result = bytes.withUnsafeBytes(measurementDigest)
      XCTAssertEqual(withUnsafeBytes(of: result) { Data($0) }, Data(SHA256.hash(data: bytes)))
    }
  }
  func testPlatformAssemblerAndWriter() throws {
    let base = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("InteropW1")
    func read(_ name: String) throws -> Data {
      try Data(contentsOf: base.appendingPathComponent(name))
    }
    let archive = try read("TEST-ONLY.TIR")
    let config = Data(#"{"flags":["debug"],"securityVersion":1,"slot":"A"}"#.utf8)
    let sidecar = try read("TEST-ONLY.SIG")
    let boot = try read("test-boot.pub")
    let system = try read("test-only.pub")
    let symbol = Data("_RIDL110LibTessera17tessera_test_openF_vea5d84f932ca1647".utf8)
    let uuid = withUnsafeBytes(of: UUID(uuidString: "ea5d84f9-32ca-1647-888d-f1c1d07d950f")!.uuid) {
      Data($0)
    }
    let textHash = Data(SHA256.hash(data: Data("function tessera_test_open() -> U32\n".utf8)))
    var hashes = [BlakeCv](
      repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    var poly = [Int32](repeating: 0, count: 2048)
    var msg = [UInt8](repeating: 0, count: 1024)
    var a = archive
    var s = sidecar
    var enrollment = boot
    var userKey = system
    var id = uuid
    var name = symbol
    var digest = textHash
    var type: UInt32 = 0x5e57_0002
    var entry: UInt32 = 0x5e57_0001
    let policy = W0Policy(
      machine: 183, baselineSupported: true, trustedUTC: 1_795_238_964,
      train: (26, 11, 1), tir: (26, 11, 2), addressLimit: 1 << 32, securityFloor: 1, slot: 0,
      debugEmulator: true)
    func validate(publicContract: Bool = false) -> Bool {
      a.withUnsafeBytes { ar in
        s.withUnsafeBytes { sig in
          enrollment.withUnsafeBytes { e in
            userKey.withUnsafeBytes { k in
              id.withUnsafeBytes { u in
                name.withUnsafeBytes { n in
                  digest.withUnsafeBytes { d in
                    hashes.withUnsafeMutableBufferPointer { h in
                      poly.withUnsafeMutableBufferPointer { w in
                        msg.withUnsafeMutableBytes { m in
                          let contract = EarlyRIDLContract(
                            uuid: u, symbol: n, textSHA256: d, typeTag: type)
                          if publicContract {
                            return authorizeQEMUStage1(
                              archive: ar, signature: sig, enrollment: e, systemEnrollment: k,
                              policy: policy, contract: contract, hashes: h, polynomials: w,
                              message: m) != nil
                          }
                          guard
                            let r = verifyStage1(
                              archive: ar, signature: sig, enrollment: e,
                              systemEnrollment: k, policy: policy, initEntryTag: entry,
                              contract: contract,
                              hashes: h, polynomials: w, message: m)
                          else { return false }
                          XCTAssertEqual(
                            r.process.bytes.baseAddress,
                            ar.baseAddress! + r.process.range.lowerBound)
                          XCTAssertEqual(
                            r.library.bytes.baseAddress,
                            ar.baseAddress! + r.library.range.lowerBound)
                          XCTAssertFalse(r.process.range.overlaps(r.library.range))
                          XCTAssertEqual(r.process.layout.code, 0x4000..<0x4020)
                          XCTAssertEqual(r.library.layout.code, 0x4000..<0x401c)
                          XCTAssertEqual(r.binding.entryRVA, 0x4010)
                          XCTAssertEqual(r.binding.slotRVA, 0x8010)
                          XCTAssertEqual(r.binding.typeTag, 0x5e57_0002)
                          checkPlacement(r)
                          XCTAssertEqual(
                            withUnsafeBytes(of: r.archiveSHA256) { Data($0) },
                            Data(SHA256.hash(data: archive)))
                          XCTAssertEqual(
                            withUnsafeBytes(of: r.configurationSHA256) { Data($0) },
                            Data(SHA256.hash(data: config)))
                          XCTAssertEqual(
                            Data(SHA256.hash(data: Data(r.process.bytes))),
                            withUnsafeBytes(of: r.initSHA256) { Data($0) })
                          return true
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    XCTAssertTrue(validate())
    XCTAssertFalse(validate(publicContract: true))
    id[0] ^= 1
    XCTAssertFalse(validate())
    id = uuid
    name[8] ^= 1
    XCTAssertFalse(validate())
    name = symbol
    digest[0] ^= 1
    XCTAssertFalse(validate())
    digest = textHash
    type += 1
    XCTAssertFalse(validate())
    type -= 1
    entry += 1
    XCTAssertFalse(validate())
    entry -= 1
    userKey = boot
    XCTAssertFalse(validate())
    userKey = system
    enrollment = system
    XCTAssertFalse(validate())
    enrollment = boot
    s[sidecar.count - 1] ^= 1
    XCTAssertFalse(validate())
    s = sidecar
    let configRange = try XCTUnwrap(a.range(of: config))
    a[configRange.lowerBound] ^= 1
    XCTAssertFalse(validate())
    a = archive
    a[24] ^= 1
    XCTAssertFalse(validate())
    a = archive

    // Re-create two separately signed negative archives. The directory digest
    // and detached envelope are valid; only the selected native signature fails.
    let index = Int(
      archive.withUnsafeBytes {
        UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
      })
    for (member, side, delta) in [("tessera.init", "init", 0), ("LibTessera", "lib", 64)] {
      var pos = index
      for _ in 0..<4 {
        let n = Int(a[pos])
        pos += 1
        let found = String(decoding: a[pos..<pos + n], as: UTF8.self) == member
        pos += n
        if found {
          func le(_ p: Int) -> Int {
            Int(
              a.withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt64.self))
              })
          }
          let start = le(pos)
          let len = le(pos + 8)
          let file = start..<start + len
          let header = try XCTUnwrap(a.range(of: Data("TSG1".utf8), options: .backwards, in: file))
            .lowerBound
          let chain = Int(
            a.withUnsafeBytes {
              UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: header + 4, as: UInt32.self))
            })
          a[header + 8 + chain + delta] ^= 1
          let root = try XCTUnwrap(
            a.withUnsafeBytes { raw in
              hashes.withUnsafeMutableBufferPointer {
                bootSetDigest(.init(rebasing: raw[file]), scratch: $0)
              }
            })
          let digest = [root.w0, root.w1, root.w2, root.w3, root.w4, root.w5, root.w6, root.w7]
            .flatMap {
              withUnsafeBytes(of: $0.littleEndian) { Array($0) }
            }
          a.replaceSubrange(pos + 25..<pos + 57, with: digest)
          break
        }
        pos += 57
      }
      s = try read("bad-" + side + ".SIG")
      let expectedArchive =
        side == "init"
        ? "2ba3405c719439df91e5dec74c10d56421fe3eb09c6e80053956a11e2af78652"
        : "1aa0c0ab40f0f425350855ad34efd4798f9027a4d9ae64e9f37f79561f5dedd1"
      XCTAssertEqual(
        SHA256.hash(data: a).map { String(format: "%02x", $0) }.joined(), expectedArchive)
      XCTAssertFalse(validate())
      a = archive
      s = sidecar
    }
  }
}

private func checkPlacement(_ set: W1BootSet) {
  let base: UInt64 = 1 << 32
  let limit: UInt64 = 1 << 43
  let page: UInt64 = 16384
  let p = base..<base + 0xc000
  let l = limit - 0x8000..<limit
  let empty = UnsafeBufferPointer<Range<UInt64>>(start: nil, count: 0)
  let slots = (limit - base) / page
  // Independently known rank counts: three pages for init then two for the
  // library. Reject the first draw, pick first init and last library.
  var words = [0, slots - 2, 2 * (slots - 4) - 1].makeIterator()
  guard let plan = set.addressPlan(occupied: empty, nextRandom: { words.next() }) else {
    return XCTFail("separate reserved image slots")
  }
  XCTAssertNil(words.next())
  XCTAssertEqual(plan.processReservation, p)
  XCTAssertEqual(plan.libraryReservation, l)
  XCTAssertEqual(plan.processEntry, base + 0x4010)
  XCTAssertEqual(plan.libraryCode, limit - 0x4000..<limit - 0x3fe4)
  XCTAssertEqual(plan.targetAddress, limit - 0x3ff0)
  XCTAssertEqual(plan.slotAddress, base + 0x8010)
  XCTAssertEqual(plan.storageModifier, 0x0002_0001_0000_8010)
  XCTAssertEqual(plan.sealReadOnly, base + 0x8000..<base + 0xc000)
  XCTAssertNil(set.addressPlan(occupied: empty, nextRandom: { nil }))
  XCTAssertNil(set.addressPlan(occupied: empty, nextRandom: { 0 }))
  [base + (minimumImagePositions + 1) * page..<limit].withUnsafeBufferPointer { occupied in
    XCTAssertNil(
      set.addressPlan(
        occupied: occupied,
        nextRandom: {
          XCTFail("insufficient space")
          return nil
        }))
  }
}
