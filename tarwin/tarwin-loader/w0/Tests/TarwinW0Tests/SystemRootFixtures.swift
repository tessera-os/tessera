import Foundation
import TarwinLoader

// Host-only variants of the same four signed members; each has its own detached signature.
enum RootFixture: String, CaseIterable {
  case valid, zero, short, long, compressed, badMemberHash, renamed, extra, overlapsImage

  static let headSHA256 = Data([
    0xac, 0xf8, 0xe3, 0x29, 0xe9, 0x80, 0xf5, 0xea, 0x25, 0x30, 0xad, 0x42, 0xc2, 0x9d,
    0x53, 0x43, 0xb0, 0x5a, 0x73, 0x39, 0xf3, 0x18, 0x83, 0xc6, 0xd6, 0x09, 0x81, 0xd3,
    0x6e, 0x23, 0x21, 0xe3,
  ])

  func archive(from ordinary: Data) -> Data {
    func le<T: FixedWidthInteger>(_ n: T) -> Data {
      withUnsafeBytes(of: n.littleEndian) { Data($0) }
    }
    let table = ordinary.withUnsafeBytes {
      Int(UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
    }
    // The last of the four sorted entries is tessera.init.
    let last = ordinary.count - (1 + "tessera.init".utf8.count + 57)
    var data = Self.headSHA256
    if self == .zero { data = Data(repeating: 0, count: 32) }
    if self == .short { data.removeLast() }
    if self == .long { data.append(0) }
    // The first payload starts at 24. Use its real hash to isolate the range check.
    if self == .overlapsImage { data = ordinary.subdata(in: 24..<56) }
    let offset = self == .overlapsImage ? 24 : table
    var scratch = [BlakeCv](
      repeating: .init(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    let cv = data.withUnsafeBytes { b in
      scratch.withUnsafeMutableBufferPointer { bootSetDigest(b, scratch: $0)! }
    }
    var hash = [cv.w0, cv.w1, cv.w2, cv.w3, cv.w4, cv.w5, cv.w6, cv.w7].reduce(into: Data()) {
      $0 += le($1)
    }
    if self == .badMemberHash { hash[0] ^= 1 }
    func record(_ name: String, _ offset: Int) -> Data {
      var r = Data([UInt8(name.utf8.count)]) + Data(name.utf8)
      r += le(UInt64(offset)) + le(UInt64(data.count)) + le(UInt64(data.count))
      r.append(self == .compressed ? 1 : 0)
      return r + hash
    }
    var result = Data(ordinary[..<table]) + data
    if self == .extra { result += data }
    result.replaceSubrange(8..<12, with: le(UInt32(self == .extra ? 6 : 5)))
    result.replaceSubrange(16..<24, with: le(UInt64(result.count)))
    result += ordinary[table..<last]
    result += record(self == .renamed ? "system.trfs.roou" : "system.trfs.root", offset)
    result += ordinary[last...]
    if self == .extra { result += record("unused", table + data.count) }
    return result
  }
}
