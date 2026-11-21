import TarbootPreflight
import Testing

private func hex(_ s: String) -> [UInt8] {
  let ascii = Array(s.utf8)
  func nibble(_ x: UInt8) -> UInt8 { x > 57 ? x - 87 : x - 48 }
  return stride(from: 0, to: ascii.count, by: 2).map {
    nibble(ascii[$0]) << 4 | nibble(ascii[$0 + 1])
  }
}

@Test func officialBLAKE3Vectors() {
  // BLAKE3 1.8.2 test_vectors.json: unkeyed, first 32 bytes, i mod 251.
  let cases = [
    (0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
    (64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"),
    (1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"),
    (1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"),
    (3072, "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2"),
    (8193, "bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b"),
    (31744, "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47"),
  ]
  var scratch = DigestScratch()
  for (size, expected) in cases {
    let input = (0..<size).map { UInt8($0 % 251) }
    let digest = hex(expected)
    input.withUnsafeBytes { payload in
      for n in [31, 32] {
        let valid = digest.prefix(n).withUnsafeBytes {
          memberDigestMatches(payload, digest: $0, scratch: &scratch)
        }
        #expect(valid == (n == 32))
      }
    }
  }
}

private func put(_ b: inout [UInt8], _ at: Int, _ size: Int, _ value: Int) {
  for i in 0..<size { b[at + i] = UInt8(truncatingIfNeeded: UInt64(value) >> (i * 8)) }
}

private func archive() -> [UInt8] {
  var k = (0..<3501).map { $0 < 512 ? 0 : UInt8($0 % 251) }
  k[0..<7] = [0x7f, 69, 76, 70, 2, 1, 1]
  for (at, width, value) in [
    (16, 2, 3), (18, 2, 183), (20, 4, 1), (24, 8, 0x4080), (32, 8, 64), (52, 2, 64),
    (54, 2, 56), (56, 2, 2), (64, 4, 1), (68, 4, 5), (80, 8, 0x4000), (96, 8, k.count),
    (104, 8, k.count),
    (112, 8, 16384), (120, 4, 4), (128, 8, 192),
  ] { put(&k, at, width, value) }
  var pos = 192
  for kind in [1, 2, 3, 4, 5, 7] {
    let size = kind == 1 ? 32 : 1
    put(&k, pos, 4, 8)
    put(&k, pos + 4, 4, size)
    put(&k, pos + 8, 4, kind)
    k[pos + 12..<pos + 20] = Array("Tessera\0".utf8)[...]
    k[pos + 20] = UInt8(kind)
    pos += 20 + ((size + 3) & ~3)
  }
  put(&k, 152, 8, pos - 192)
  let table = 24 + k.count
  var b = [UInt8](repeating: 0, count: 24)
  b[0..<4] = Array("TIRA".utf8)[...]
  put(&b, 4, 2, 1)
  put(&b, 8, 4, 1)
  put(&b, 16, 8, table)
  b += k
  b += [6]
  b += "kernel".utf8
  let rec = b.count
  b += Array(repeating: 0, count: 25)
  put(&b, rec, 8, 24)
  put(&b, rec + 8, 8, k.count)
  put(&b, rec + 16, 8, k.count)
  // Independently calculated by the reference Python blake3 1.0.8 binding.
  b += hex("d6d2f06a07f83cedb93e2b5be8841e3b61dd530d4b12a5e0fe6b068aa6d9a94f")
  return b
}

@Test func pinnedArchiveAndELF() {
  var scratch = DigestScratch()
  func inspect(_ b: [UInt8], _ name: String = "kernel", _ target: UInt16 = 183) -> KernelPreflight {
    b.withUnsafeBytes { a in
      Array(name.utf8).withUnsafeBytes {
        inspectBootKernel(a, path: $0, target: target, addressLimit: 0x10000, scratch: &scratch)
      }
    }
  }
  let b = archive()
  guard case .inspected(let range, let image) = inspect(b) else {
    Issue.record("valid member rejected")
    return
  }
  #expect(range == 24..<3525)
  #expect(image.entry == 0x4080)
  #expect(image.notes.buildID == 212..<244)
  if case .notFound = inspect(b, "absent") {} else { Issue.record("missing name") }
  if case .invalidELF = inspect(b, "kernel", 62) {} else { Issue.record("wrong architecture") }
  for i in [24, 24 + 1024, 3524, b.count - 1] {
    var bad = b
    bad[i] ^= 1
    if case .digestMismatch = inspect(bad) {} else { Issue.record("corruption at \(i)") }
  }
  var compressed = b
  compressed[b.count - 33] = 1
  if case .compressed = inspect(compressed) {} else { Issue.record("unchecked compressed kernel") }
  if case .invalidArchive = inspect(b + [0]) {} else { Issue.record("trailing bytes") }
}
