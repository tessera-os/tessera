import CommonCrypto
import CryptoKit
import Foundation
import XCTest

@testable import TRFS

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent()

/// IEEE 1619 key = data key (first 32 bytes) || tweak key (last 32 bytes).
/// Apple's CommonCrypto supplies only single-block AES; XTS is TRFS's XtsSector.
struct HostXts: XtsCipher {
  let keyObject: UInt64 = 1
  let dataKey: [UInt8], tweakKey: [UInt8]
  init(_ key: [UInt8]) {
    precondition(key.count == 64)
    dataKey = Array(key[..<32])
    tweakKey = Array(key[32...])
  }
  private func aes(_ b: CipherBlock, _ key: [UInt8], decrypt: Bool) -> CipherBlock? {
    var source = (b.low.littleEndian, b.high.littleEndian)
    var result = (UInt64(0), UInt64(0))
    var n = 0
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
  func data(_ b: CipherBlock, decrypt: Bool) -> CipherBlock? { aes(b, dataKey, decrypt: decrypt) }
  func encryptTweak(_ b: CipherBlock) -> CipherBlock? { aes(b, tweakKey, decrypt: false) }
}

/// One whole data unit through XtsSector, as the volume drives it.
func xtsSector(_ input: [UInt8], key: [UInt8], tweak: UInt64, decrypt: Bool) -> [UInt8]? {
  let cache = UnsafeMutableRawBufferPointer.allocate(byteCount: input.count, alignment: 16)
  let stage = UnsafeMutableRawBufferPointer.allocate(byteCount: input.count, alignment: 16)
  defer {
    cache.deallocate()
    stage.deallocate()
  }
  guard let cp = SectorPin(physical: 0x10_0000, bytes: cache),
    let sp = SectorPin(physical: 0x200_0000, bytes: stage),
    var io = XtsSector(unit: .init(block: 9, tweak: tweak, keyObject: 1), cache: cp, staging: sp)
  else { return nil }
  var cipher = HostXts(key)
  let erase: (UnsafeMutableRawBufferPointer) -> Void = { $0.initializeMemory(as: UInt8.self, repeating: 0) }
  if !decrypt { cache.copyBytes(from: input) }
  // XtsSector erases the stage once the write completes; the "device" copies it at issue.
  var written = [UInt8]()
  guard
    io.begin(read: decrypt, cipher: &cipher, erase: erase, issue: { _, _, _, _ in
      if decrypt { stage.copyBytes(from: input) } else { written = Array(stage) }
      return true
    }),
    io.finish(transferred: input.count, cipher: &cipher, drain: { true }, erase: erase)
      == .completed
  else { return nil }
  return decrypt ? Array(cache) : written
}

func sha256Digest(_ b: UnsafeRawBufferPointer) -> TrfsDigest {
  SHA256.hash(data: Data(b)).withUnsafeBytes { TrfsDigest($0)! }
}

final class PlainDisk: TrfsMedia {
  var disk: [Data]
  init(blocks: Int) { disk = .init(repeating: Data(count: 4096), count: blocks) }
  var blocks: UInt64 { UInt64(disk.count) }
  func read(_ block: UInt64, into: UnsafeMutableRawBufferPointer) -> Bool {
    guard block < blocks else { return false }
    disk[Int(block)].copyBytes(to: into)
    return true
  }
  func write(_ block: UInt64, from: UnsafeRawBufferPointer) -> Bool {
    guard block < blocks else { return false }
    disk[Int(block)] = Data(from)
    return true
  }
  func flush() -> Bool { true }
  func sha256(_ bytes: UnsafeRawBufferPointer) -> TrfsDigest { sha256Digest(bytes) }
}

final class CipherDisk: TrfsRetiredBlockIO {
  let stage: SectorPin
  var disk: [Data]
  init(_ pin: SectorPin, image: [Data]) {
    stage = pin
    disk = image
  }
  var blocks: UInt64 { UInt64(disk.count) }
  func transfer(_ block: UInt64, physical: UInt64, count: Int, read: Bool) -> Int? {
    guard block < blocks, physical == stage.physical, count == 4096 else { return nil }
    if read { disk[Int(block)].copyBytes(to: stage.bytes) } else { disk[Int(block)] = Data(stage.bytes) }
    return count
  }
  func flush() -> Bool { true }
  func erase(_ b: UnsafeMutableRawBufferPointer) { b.initializeMemory(as: UInt8.self, repeating: 0) }
  func sha256(_ b: UnsafeRawBufferPointer) -> TrfsDigest { sha256Digest(b) }
}

/// Four kernel-owned pages: private cache, ciphertext stage, volume scratch, client buffer.
final class Pages {
  let p = (0..<4).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096) }
  var cache: SectorPin { SectorPin(physical: 0x1000, bytes: p[0])! }
  var stage: SectorPin { SectorPin(physical: 0x2000, bytes: p[1])! }
  deinit { for x in p { x.deallocate() } }
}

func image(_ d: [Data]) -> Data { d.reduce(into: Data()) { $0.append($1) } }
func sectors(_ d: Data) -> [Data] {
  stride(from: 0, to: d.count, by: 4096).map { Data(d[$0..<($0 + 4096)]) }
}
func hex(_ b: some Sequence<UInt8>) -> String { b.map { String(format: "%02x", $0) }.joined() }
func bytes(hex s: String) -> [UInt8] {
  var out = [UInt8](), i = s.startIndex
  while i < s.endIndex {
    let j = s.index(i, offsetBy: 2)
    out.append(UInt8(s[i..<j], radix: 16)!)
    i = j
  }
  return out
}

/// Runs tools/xts_ref.py with TRFS_XREF_PYTHON (a Python with pyca/cryptography).
/// A missing reference skips; it is never reported as a pass.
struct Reference {
  let python: String
  let script = packageRoot.appendingPathComponent("tools/xts_ref.py").path
  init() throws {
    guard let py = ProcessInfo.processInfo.environment["TRFS_XREF_PYTHON"] else {
      throw XCTSkip("set TRFS_XREF_PYTHON (see run.sh): external XTS references unavailable")
    }
    python = py
    _ = try run(["version"])
  }
  @discardableResult
  func run(_ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: python)
    p.arguments = [script] + args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      throw NSError(
        domain: "xts_ref", code: Int(p.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: o + e, as: UTF8.self)])
    }
    return String(decoding: o, as: UTF8.self)
  }
}
