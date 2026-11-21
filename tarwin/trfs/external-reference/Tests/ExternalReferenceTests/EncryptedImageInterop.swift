import CryptoKit
import Foundation
import XCTest

@testable import TRFS

/// A whole TRFS v1 encrypted volume exchanged with independent XTS-AES-256
/// implementations, sector by sector with the TRFS tweak (LE sector index).
final class EncryptedImageInteropTests: XCTestCase {
  static let key: [UInt8] =
    Array(SHA256.hash(data: Data("trfs-xref data key".utf8)))
    + Array(SHA256.hash(data: Data("trfs-xref tweak key".utf8)))
  static let blocks = 32
  static let page0 = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
  static let tail = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
  static let link = Array("docs/report.bin".utf8)
  var tmp: URL!

  override func setUpWithError() throws {
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trfs-xref-\(UUID())")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

  static var fileBytes: Data { page0 + Data(count: 4096) + tail }
  static var expect: [[String: Any]] {
    [
      ["path": "docs", "kind": "directory"],
      ["path": "docs/report.bin", "kind": "file", "sha256": hex(SHA256.hash(data: fileBytes))],
      ["path": "latest", "kind": "symlink", "sha256": hex(SHA256.hash(data: Data(link)))],
    ]
  }

  /// Directory, sparse file with an EOF fragment, and a relative link.
  static func populate<M: TrfsMedia>(_ v: inout TrfsVolume<M>) -> TrfsSnapshot? {
    guard v.formatBlank(), let dir = v.create(1, name: Array("docs".utf8), kind: .directory),
      let f = v.create(dir, name: Array("report.bin".utf8), kind: .file),
      page0.withUnsafeBytes({ v.writePage(f, index: 0, bytes: $0) }),
      tail.withUnsafeBytes({ v.writePage(f, index: 2, bytes: $0) }),
      v.createSymlink(1, name: Array("latest".utf8), target: link) != nil
    else { return nil }
    return v.snapshot
  }

  func plainImage() throws -> (Data, TrfsSnapshot) {
    let pages = Pages()
    let disk = PlainDisk(blocks: Self.blocks)
    var v = TrfsVolume(media: disk, scratch: pages.p[2])!
    let root = try XCTUnwrap(Self.populate(&v))
    return (image(disk.disk), root)
  }

  func external(_ ref: Reference, _ impl: String, _ mode: String, _ input: Data,
                tweak: String = "le", key: [UInt8] = key) throws -> Data {
    let i = tmp.appendingPathComponent(UUID().uuidString), o = tmp.appendingPathComponent(UUID().uuidString)
    try input.write(to: i)
    try ref.run(["crypt", "--impl", impl, "--mode", mode, "--tweak", tweak, "--key", hex(key),
                 "--input", i.path, "--output", o.path])
    return try Data(contentsOf: o)
  }

  func checkLayout(_ ref: Reference, _ plain: Data, _ root: TrfsSnapshot) throws -> String {
    let img = tmp.appendingPathComponent("plain.img"), exp = tmp.appendingPathComponent("expect.json")
    try plain.write(to: img)
    try JSONSerialization.data(withJSONObject: Self.expect).write(to: exp)
    var d = [UInt8](repeating: 0, count: 32)
    _ = d.withUnsafeMutableBytes { root.digest.encode(into: $0) }
    return try ref.run(["check", img.path, "--root", hex(d), "--expect", exp.path])
  }

  /// Mount `ciphertext` through TrfsEncryptedMedia and read everything back.
  func mountAndRead(_ ciphertext: Data, root: TrfsSnapshot) throws -> Bool {
    let pages = Pages()
    let disk = CipherDisk(pages.stage, image: sectors(ciphertext))
    var key = HostXts(Self.key)
    return try withUnsafeMutablePointer(to: &key) { k in
      let media = try XCTUnwrap(
        TrfsEncryptedMedia(io: disk, cipher: k, privatePage: pages.cache, ciphertext: pages.stage))
      var v = TrfsVolume(media: media, scratch: pages.p[2])!
      guard v.mount(expected: root.digest) else { return false }
      guard case .directory(let dir) = v.lookup(1, name: Array("docs".utf8), in: root),
        case .file(let f) = v.lookup(dir, name: Array("report.bin".utf8), in: root),
        case .symlink = v.lookup(1, name: Array("latest".utf8), in: root)
      else { return false }
      var got = Data()
      for i in 0..<3 {
        guard let n = v.readPage(f, index: UInt64(i), in: root, into: pages.p[3]) else { return false }
        got += Data(pages.p[3].prefix(n))
      }
      return got == Self.fileBytes
    }
  }

  func testTrfsCiphertextDecryptsWithPycaAndLibreSSL() throws {
    let ref = try Reference()
    let pages = Pages()
    let disk = CipherDisk(pages.stage, image: .init(repeating: Data(count: 4096), count: Self.blocks))
    var key = HostXts(Self.key)
    let root: TrfsSnapshot = try withUnsafeMutablePointer(to: &key) { k in
      let media = try XCTUnwrap(
        TrfsEncryptedMedia(io: disk, cipher: k, privatePage: pages.cache, ciphertext: pages.stage))
      pages.p[3].initializeMemory(as: UInt8.self, repeating: 0)
      XCTAssertTrue(media.write(0, from: .init(pages.p[3])))
      XCTAssertTrue(media.write(1, from: .init(pages.p[3])))
      var v = TrfsVolume(media: media, scratch: pages.p[2])!
      return try XCTUnwrap(Self.populate(&v))
    }
    let cipher = image(disk.disk)
    let pyca = try external(ref, "pyca", "dec", cipher)
    let libre = try external(ref, "libressl", "dec", cipher)
    XCTAssertEqual(pyca, libre)
    let layout = try checkLayout(ref, pyca, root)
    print("layout check:", layout)
    let tail = try XCTUnwrap(
      (JSONSerialization.jsonObject(with: Data(layout.utf8)) as? [String: Any])?["tail"] as? Int)
    // Sectors past the tail were never written; only written ones are compared.
    XCTAssertEqual(
      pyca.prefix(tail * 4096), try plainImage().0.prefix(tail * 4096),
      "decrypted image equals the plaintext writer's image")
  }

  func testExternallyEncryptedImageMountsAndReads() throws {
    let ref = try Reference()
    let (plain, root) = try plainImage()
    print("layout check:", try checkLayout(ref, plain, root))
    let pyca = try external(ref, "pyca", "enc", plain)
    XCTAssertEqual(pyca, try external(ref, "libressl", "enc", plain))
    XCTAssertTrue(try mountAndRead(pyca, root: root))
  }

  func testMisencryptedOrRearrangedImagesNeverMountOrRead() throws {
    let ref = try Reference()
    let (plain, root) = try plainImage()
    var flipped = Self.key
    flipped[40] ^= 1
    let swappedKey = Array(Self.key[32...] + Self.key[..<32])
    let cases: [(String, Data)] = [
      ("tweak = sector + 1", try external(ref, "pyca", "enc", plain, tweak: "plus1")),
      ("big-endian tweak", try external(ref, "libressl", "enc", plain, tweak: "be")),
      ("key halves swapped", try external(ref, "pyca", "enc", plain, key: swappedKey)),
      ("one tweak-key bit", try external(ref, "libressl", "enc", plain, key: flipped)),
    ]
    for (name, c) in cases {
      XCTAssertFalse(try mountAndRead(c, root: root), name)
    }
    let good = sectors(try external(ref, "pyca", "enc", plain))
    var anchors = good
    anchors.swapAt(0, 1)
    var records = good
    records.swapAt(3, 4)
    var bit = good
    let dataSector = (2..<Self.blocks).first { plain[$0 * 4096..<$0 * 4096 + 4096] == Self.page0 }!
    bit[dataSector][100] ^= 0x80
    for (name, s) in [("anchors swapped", anchors), ("records swapped", records), ("data bit", bit)] {
      XCTAssertFalse(try mountAndRead(image(s), root: root), name)
    }
  }

  func testOnlyEncryptedZeroAnchorsFormat() throws {
    let ref = try Reference()
    for (zeroCipher, formats) in [(true, true), (false, false)] {
      let zeros = Data(count: 2 * 4096)
      let anchors = zeroCipher ? try external(ref, "libressl", "enc", zeros) : zeros
      let pages = Pages()
      let disk = CipherDisk(
        pages.stage, image: sectors(anchors) + .init(repeating: Data(count: 4096), count: 6))
      var key = HostXts(Self.key)
      try withUnsafeMutablePointer(to: &key) { k in
        let media = try XCTUnwrap(
          TrfsEncryptedMedia(io: disk, cipher: k, privatePage: pages.cache, ciphertext: pages.stage))
        var v = TrfsVolume(media: media, scratch: pages.p[2])!
        XCTAssertEqual(v.formatBlank(), formats)
      }
    }
  }
}
