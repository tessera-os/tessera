import CommonCrypto
import CryptoKit
import Foundation
import XCTest

@testable import TRFS

// Test-only fixed keys. Production resolves a retained key object instead.
private struct HostAES: XtsCipher {
  let keyObject: UInt64 = 123
  func aes(_ b: CipherBlock, keyByte: UInt8, decrypt: Bool) -> CipherBlock? {
    var source = (b.low.littleEndian, b.high.littleEndian)
    var result = (UInt64(0), UInt64(0))
    var n = 0
    let key = [UInt8](repeating: keyByte, count: 32)
    let status = withUnsafeBytes(of: &source) { s in
      withUnsafeMutableBytes(of: &result) { d in
        key.withUnsafeBytes { k in
          CCCrypt(
            CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode), k.baseAddress, k.count, nil, s.baseAddress, 16,
            d.baseAddress, 16, &n)
        }
      }
    }
    guard status == kCCSuccess, n == 16 else { return nil }
    return CipherBlock(low: .init(littleEndian: result.0), high: .init(littleEndian: result.1))
  }
  func data(_ b: CipherBlock, decrypt: Bool) -> CipherBlock? {
    aes(b, keyByte: 17, decrypt: decrypt)
  }
  func encryptTweak(_ b: CipherBlock) -> CipherBlock? { aes(b, keyByte: 34, decrypt: false) }
}
private final class CipherDisk: TrfsRetiredBlockIO {
  let blocks: UInt64 = 16, stage: SectorPin
  var disk = [Data](repeating: Data(repeating: 0, count: 4096), count: 16), short = false
  init(_ pin: SectorPin) { stage = pin }
  func transfer(_ block: UInt64, physical: UInt64, count: Int, read: Bool) -> Int? {
    XCTAssertEqual(physical, stage.physical)
    XCTAssertEqual(count, 4096)
    guard block < blocks else { return nil }
    if read {
      disk[Int(block)].copyBytes(to: stage.bytes)
    } else {
      disk[Int(block)] = Data(stage.bytes)
    }
    return short ? 4095 : 4096
  }
  func flush() -> Bool { true }
  func erase(_ b: UnsafeMutableRawBufferPointer) {
    b.initializeMemory(as: UInt8.self, repeating: 0)
  }
  func sha256(_ b: UnsafeRawBufferPointer) -> TrfsDigest {
    SHA256.hash(data: Data(b)).withUnsafeBytes { TrfsDigest($0)! }
  }
}
final class EncryptedVolumeTests: XCTestCase {
  func testEncryptedAnchorsAndPayloadThroughRemountAndShortRead() throws {
    let pages = (0..<4).map { _ in
      UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    }
    defer { for p in pages { p.deallocate() } }
    let cache = SectorPin(physical: 0x1000, bytes: pages[0])!
    let stage = SectorPin(physical: 0x2000, bytes: pages[1])!
    let d = CipherDisk(stage)
    var key = HostAES()
    try withUnsafeMutablePointer(to: &key) { k in
      let media = try XCTUnwrap(
        TrfsEncryptedMedia(io: d, cipher: k, privatePage: cache, ciphertext: stage))
      pages[3].initializeMemory(as: UInt8.self, repeating: 0)
      // Explicit privileged provisioning of the *plaintext* blank anchors.
      XCTAssertTrue(media.write(0, from: .init(pages[3])))
      XCTAssertTrue(media.write(1, from: .init(pages[3])))
      XCTAssertNotEqual(d.disk[0], d.disk[1])  // same plaintext, distinct tweaks
      XCTAssertFalse(media.write(2, from: .init(stage.bytes)))
      var v = TrfsVolume(media: media, scratch: pages[2])!
      XCTAssertTrue(v.formatBlank())
      let name = Array("private-name".utf8)
      let content = Data(repeating: 0xa7, count: 4096)
      let id = try XCTUnwrap(v.create(1, name: name, kind: .file))
      XCTAssertTrue(content.withUnsafeBytes { v.writePage(id, index: 0, bytes: $0) })
      let root = try XCTUnwrap(v.snapshot)
      for page in d.disk {
        XCTAssertNotEqual(page, content)
        XCTAssertNil(page.range(of: Data(name)))
        XCTAssertNil(page.range(of: Data("TRFS".utf8)))
      }
      var reader = TrfsVolume(media: media, scratch: pages[2])!
      XCTAssertTrue(reader.mount(expected: root.digest))
      XCTAssertEqual(reader.lookup(1, name: name, in: root), .file(id))
      XCTAssertEqual(reader.readPage(id, index: 0, in: root, into: pages[3]), 4096)
      XCTAssertEqual(Data(pages[3]), content)
      d.short = true
      pages[3].initializeMemory(as: UInt8.self, repeating: 0xce)
      XCTAssertNil(reader.readPage(id, index: 0, in: root, into: pages[3]))
      XCTAssertTrue(pages[3].allSatisfy { $0 == 0xce })
      XCTAssertTrue(cache.bytes.allSatisfy { $0 == 0 })
      XCTAssertTrue(stage.bytes.allSatisfy { $0 == 0 })
    }
  }
}
