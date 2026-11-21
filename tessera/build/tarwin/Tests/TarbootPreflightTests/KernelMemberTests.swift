import TarbootPreflight
import Testing

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
