import CommonCrypto
import CryptoKit
import Foundation
import TRFS

private func hex<S: Sequence>(_ bs: S) -> String where S.Element == UInt8 {
  bs.map { String(format: "%02x", $0) }.joined()
}
private func decode(_ text: String) -> [UInt8] {
  var result: [UInt8] = []
  var i = text.startIndex
  while let j = text.index(i, offsetBy: 2, limitedBy: text.endIndex),
    let b = UInt8(text[i..<j], radix: 16)
  {
    result.append(b)
    i = j
  }
  return result
}
// Public IEEE P1619 AES-256-XTS vector, data-unit ff, from OpenSSL's
// test/recipes/30-test_evp_data/evpciph_aes_common.txt. Host test keys only.
private struct VectorCipher: XtsCipher {
  let keyObject: UInt64 = 99
  let k1 = decode("2718281828459045235360287471352662497757247093699959574966967627")
  let k2 = decode("3141592653589793238462643383279502884197169399375105820974944592")
  private func aes(_ b: CipherBlock, _ key: [UInt8], _ decrypt: Bool) -> CipherBlock? {
    var src = (b.low.littleEndian, b.high.littleEndian)
    var dst = (UInt64(0), UInt64(0))
    var n = 0
    let rc = withUnsafeBytes(of: &src) { p in
      withUnsafeMutableBytes(of: &dst) { out in
        key.withUnsafeBytes { k in
          CCCrypt(
            CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode), k.baseAddress, k.count, nil, p.baseAddress, 16,
            out.baseAddress, 16, &n)
        }
      }
    }
    guard rc == kCCSuccess, n == 16 else { return nil }
    return CipherBlock(low: UInt64(littleEndian: dst.0), high: UInt64(littleEndian: dst.1))
  }
  func encryptTweak(_ b: CipherBlock) -> CipherBlock? { aes(b, k2, false) }
  func data(_ b: CipherBlock, decrypt: Bool) -> CipherBlock? { aes(b, k1, decrypt) }
}
/// QTest memory is remote. Copy only the ciphertext staging span across that
/// boundary, never the private cache. Both host mirrors outlive the drain.
final class EncryptedSectorCheck {
  let frame: UInt64, read: Bool
  private let cache: UnsafeMutableRawBufferPointer, stage: UnsafeMutableRawBufferPointer
  private var transfer: XtsSector, cipher = VectorCipher()
  static func expectedCiphertext(_ b: Data) -> Bool {
    b.count == 512
      && hex(SHA256.hash(data: b))
        == "e97e974fa393af794f7a4684395814cf820de60a01eaec677d87b452e316b364"
  }
  init(frame: UInt64, read: Bool) {
    self.frame = frame
    self.read = read
    cache = .allocate(byteCount: 512, alignment: 16)
    stage = .allocate(byteCount: 512, alignment: 16)
    for i in cache.indices { cache[i] = read ? 0x89 : UInt8(truncatingIfNeeded: i) }
    transfer = XtsSector(
      unit: EncryptedUnit(block: 7, tweak: 255, keyObject: 99),
      cache: SectorPin(physical: 0x3f00000, bytes: cache)!,
      staging: SectorPin(physical: frame, bytes: stage)!)!
  }
  deinit {
    cache.deallocate()
    stage.deallocate()
  }
  private static func erase(_ b: UnsafeMutableRawBufferPointer) { for i in b.indices { b[i] = 0 } }
  func prepare(_ q: QTest) throws {
    let frame = self.frame
    let read = self.read
    let stage = self.stage
    let ok = transfer.begin(read: read, cipher: &cipher, erase: Self.erase) { lba, p, n, w in
      guard lba == 7, p == frame, n == 512, w == read else { return false }
      if !read && !Self.expectedCiphertext(Data(stage)) { return false }
      _ = q.send("write \(p) 512 0x" + hex(stage))
      return q.error == nil
    }
    try q.require(ok, "XTS known-answer staging failed")
  }
  func finish(_ q: QTest, success: Bool, retire: () -> Bool) -> Bool {
    let read = self.read
    let stage = self.stage
    let frame = self.frame
    var copied = false
    let result = transfer.finish(
      transferred: success ? 512 : nil, cipher: &cipher,
      drain: {
        guard retire() else { return false }
        if read {
          let wire = q.send("read \(frame) 512")
          if wire.hasPrefix("0x") {
            let data = decode(String(wire.dropFirst(2)))
            if Self.expectedCiphertext(Data(data)) {
              stage.copyBytes(from: data)
              copied = true
            }
          }
        }
        return true
      }, erase: Self.erase)
    guard result == .completed, stage.allSatisfy({ $0 == 0 }), !read || copied else { return false }
    _ = q.send("memset \(frame) 512 0")
    return q.error == nil && cache.indices.allSatisfy { cache[$0] == UInt8(truncatingIfNeeded: $0) }
  }
}
