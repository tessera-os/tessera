import Testing

@testable import Stage0Image

// Two function sections; the entry calls the second by a section-relative
// relocation. A12 must receive the relocation, not just the instruction bytes.
private func input(x64: Bool = false) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: 64 + 7 * 64)
  func put(_ offset: Int, _ n: Int, _ v: UInt64) {
    for i in 0..<n { b[offset + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
  }
  b[0..<7] = [127, 69, 76, 70, 2, 1, 1]
  put(16, 2, 1)
  put(18, 2, x64 ? 62 : 183)
  put(20, 4, 1)
  put(40, 8, 64)
  put(52, 2, 64)
  put(58, 2, 64)
  put(60, 2, 7)
  put(62, 2, 6)
  let names = [
    "", ".text.start", ".text.rest", ".rela.text.start", ".symtab", ".strtab", ".shstrtab",
  ]
  var strings = [UInt8]()
  var offsets = [Int]()
  for name in names {
    offsets.append(strings.count)
    strings += Array(name.utf8) + [0]
  }
  func add(
    _ idx: Int, _ type: Int, _ flags: Int, _ bytes: [UInt8], alignment: Int = 1, link: Int = 0,
    info: Int = 0, ent: Int = 0
  ) -> Int {
    let h = 64 + idx * 64
    let at = b.count
    put(h, 4, UInt64(offsets[idx]))
    put(h + 4, 4, UInt64(type))
    put(h + 8, 8, UInt64(flags))
    put(h + 24, 8, UInt64(at))
    put(h + 32, 8, UInt64(bytes.count))
    put(h + 40, 4, UInt64(link))
    put(h + 44, 4, UInt64(info))
    put(h + 48, 8, UInt64(alignment))
    put(h + 56, 8, UInt64(ent))
    b += bytes
    return at
  }
  _ = add(1, 1, 6, x64 ? [0xe9, 0, 0, 0, 0] : [0, 0, 0, 0x94], alignment: x64 ? 1 : 4)
  _ = add(2, 1, 6, x64 ? [0xc3] : [0xc0, 3, 0x5f, 0xd6], alignment: x64 ? 1 : 4)
  let rel = add(3, 4, 0, [UInt8](repeating: 0, count: 24), link: 4, info: 1, ent: 24)
  put(rel, 8, x64 ? 1 : 0)
  put(rel + 8, 8, 2 << 32 | (x64 ? 4 : 283))
  if x64 { put(rel + 16, 8, UInt64(bitPattern: -4)) }
  let syms = add(4, 2, 0, [UInt8](repeating: 0, count: 72), link: 5, ent: 24)
  put(syms + 24, 4, 1)
  put(syms + 28, 1, 0x12)
  put(syms + 30, 2, 1)
  put(syms + 40, 8, x64 ? 5 : 4)
  put(syms + 54, 2, 2)
  _ = add(5, 3, 0, Array("\0tarwin_start_body\0".utf8))
  _ = add(6, 3, 0, strings)
  return b
}

@Test func patchesCallAndRetainsUnsignedKernelMetadata() throws {
  let image = try packageKernel(readKernelObject(input()))
  #expect(image.entryAddress == 0x4010)
  #expect(Array(image.bytes[0x400c..<0x4018]) == [0x60,0x50,0x41,0xd4,0x5f,0x24,3,0xd5,1,0,0,0x14])
  #expect(Array(image.bytes[0x4018..<0x4020]) == [1, 0, 0, 0x94, 0xc0, 3, 0x5f, 0xd6])
}

@Test func rejectsBrokenAndUnsupportedInputs() {
  let b = input()
  for n in [0, 63, 128, b.count - 1] {
    #expect(throws: InputError.self) { try readKernelObject(Array(b.prefix(n))) }
  }
  for (off, v): (Int, UInt8) in [
    (18, 62), (128 + 8, 7), (64 + 8, 2), (64 + 3 * 64 + 40, 1), (64 + 3 * 64 + 56, 8),
    (64 + 7 * 64 + 8 + 8, 0xff), (64 + 7 * 64 + 8 + 12, 9), (64 + 7 * 64 + 8 + 16, 12),
  ] {
    var bad = b
    bad[off] = v
    #expect(throws: InputError.self) { try readKernelObject(bad) }
  }
}

@Test func x64VeneerCallsSwiftBodyWithResolvedRelativeBranch() throws {
  let image = try packageKernel(readKernelObject(input(x64: true)))
  #expect(image.entryAddress == 0x1010)
  #expect(Array(image.bytes[0x100b..<0x1019]) == [
    0xb8, 0x60, 0x50, 0x41, 0xd4, 0xf3, 0x0f, 0x1e, 0xfa, 0xe9, 0, 0, 0, 0,
  ])
  #expect(Array(image.bytes[0x1019..<0x101f]) == [0xe9, 0, 0, 0, 0, 0xc3])
}
