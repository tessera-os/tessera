@testable import TarwinLoader

// BLAKE3 1.8.2 test_vectors/test_vectors.json, unkeyed hash, first 32
// bytes. Input byte at offset i = i % 251. Expected roots are independent
// of both the compressor and proof builder.
func vectorWord(_ at: UInt64, _ end: UInt64, _ corrupt: Bool) -> UInt32 {
  var result: UInt32 = 0
  for byte in 0..<4 {
    let pos = at + UInt64(byte)
    if pos < end {
      var v = UInt32(pos % 251)
      if corrupt && pos == 33 { v = v ^ 1 }
      result = result | (v << UInt32(byte * 8))
    }
  }
  return result
}

func vectorWords(_ at: UInt64, _ end: UInt64, _ corrupt: Bool) -> BlakeCv {
  return BlakeCv(
    w0: vectorWord(at + 0, end, corrupt),
    w1: vectorWord(at + 4, end, corrupt),
    w2: vectorWord(at + 8, end, corrupt),
    w3: vectorWord(at + 12, end, corrupt),
    w4: vectorWord(at + 16, end, corrupt),
    w5: vectorWord(at + 20, end, corrupt),
    w6: vectorWord(at + 24, end, corrupt),
    w7: vectorWord(at + 28, end, corrupt))
}

func vectorLeaf(_ size: UInt64, _ index: UInt64, _ corrupt: Bool) -> ImageChunkProof {
  var proof = imageChunk(size, index)
  var offset = index * 1024
  var end = offset + 1024
  if size < end { end = size }
  while !proof.hashed && !proof.failed {
    let block = BlakeBlock(
      low: vectorWords(offset, end, corrupt),
      high: vectorWords(offset + 32, end, corrupt))
    var len = end - offset
    if len > 64 { len = 64 }
    if !proof.absorb(block, UInt32(len)) { return proof }
    offset += len
  }
  return proof
}

func integrityCases() -> Int {
  let r0 = BlakeCv(
    w0: 0xb949_13af,
    w1: 0xa6a1_f9f5,
    w2: 0xea4d_40a0,
    w3: 0x49c9_dc36,
    w4: 0xc925_cb9b,
    w5: 0xb712_c1ad,
    w6: 0xca93_9acc,
    w7: 0x6232_1fe4)
  if !vectorLeaf(0, 0, false).verifies(r0) { return 21 }
  let r63 = BlakeCv(
    w0: 0xa537_bce9,
    w1: 0x83ad_da94,
    w2: 0xdf70_94be,
    w3: 0x9837_7b7f,
    w4: 0x833d_7c29,
    w5: 0xa80b_e84c,
    w6: 0x7620_6e5d,
    w7: 0x7bdb_b727)
  if !vectorLeaf(63, 0, false).verifies(r63) { return 22 }
  let r64 = BlakeCv(
    w0: 0x4171_ed4e,
    w1: 0xd45c_4aea,
    w2: 0x6b60_88b7,
    w3: 0xe246_3fd2,
    w4: 0xac9c_af12,
    w5: 0x7ddc_aceb,
    w6: 0xc76d_4c1f,
    w7: 0x981b_51f2)
  if !vectorLeaf(64, 0, false).verifies(r64) { return 23 }
  let r65 = BlakeCv(
    w0: 0xa05f_1ede,
    w1: 0x6ddf_70be,
    w2: 0xfdff_e82b,
    w3: 0xaace_990e,
    w4: 0xc9e8_b68e,
    w5: 0xd8f2_633a,
    w6: 0xcb0e_c3d1,
    w7: 0xee3d_266b)
  if !vectorLeaf(65, 0, false).verifies(r65) { return 24 }
  let r1023 = BlakeCv(
    w0: 0x7089_1010,
    w1: 0xb93e_daee,
    w2: 0x14ac_ba32,
    w3: 0x16a2_c728,
    w4: 0x4c92_0e3b,
    w5: 0xb325_9e9a,
    w6: 0xb272_ba5b,
    w7: 0x11bd_708f)
  if !vectorLeaf(1023, 0, false).verifies(r1023) { return 25 }
  let r1024 = BlakeCv(
    w0: 0x3947_2142,
    w1: 0x06a4_95f0,
    w2: 0xde83_fcf3,
    w3: 0x4a74_89b8,
    w4: 0x31f8_0dc0,
    w5: 0x55aa_0dc1,
    w6: 0x125d_9b18,
    w7: 0xf75a_851c)
  if !vectorLeaf(1024, 0, false).verifies(r1024) { return 26 }
  let size: UInt64 = 4097
  let root = BlakeCv(
    w0: 0xb352_409b,
    w1: 0xc85f_1c8f,
    w2: 0x7aff_f9b1,
    w3: 0xd27c_b2c7,
    w4: 0x3d7b_4842,
    w5: 0xc915_0d89,
    w6: 0xb825_1c6a,
    w7: 0x95b9_0faa)
  var a = vectorLeaf(size, 0, false)
  var b = vectorLeaf(size, 1, false)
  var c = vectorLeaf(size, 2, false)
  var d = vectorLeaf(size, 3, false)
  var e = vectorLeaf(size, 4, false)
  let acv = a.chain
  let bcv = b.chain
  let ccv = c.chain
  let dcv = d.chain
  let ecv = e.chain
  let ab = imageParentCv(acv, bcv)
  let cd = imageParentCv(ccv, dcv)
  let left = imageParentCv(ab, cd)
  if !checkPinned(root, left) { return 45 }
  if !a.sibling(bcv) || !a.sibling(cd) || a.verifies(root) || !a.sibling(ecv) { return 27 }
  if !b.sibling(acv) || !b.sibling(cd) || !b.sibling(ecv) { return 28 }
  if !c.sibling(dcv) || !c.sibling(ab) || !c.sibling(ecv) { return 29 }
  if !d.sibling(ccv) || !d.sibling(ab) || !d.sibling(ecv) { return 30 }
  if !e.sibling(left) || !e.verifies(root) { return 31 }
  var first = pageIntegrity(size, 0, 4096, root)
  if !first.accept(a) || !first.accept(b) || !first.accept(c) || first.verified() { return 32 }
  if !first.accept(d) || !first.verified() { return 33 }
  var last = pageIntegrity(size, 4096, 4096, root)
  if !last.accept(e) || !last.verified() { return 34 }
  var large = pageIntegrity(size, 0, 16384, root)
  if !large.accept(a) || !large.accept(b) || !large.accept(c)
    || !large.accept(
      d
    ) || large.verified()
  {
    return 35
  }
  if !large.accept(e) || !large.verified() { return 36 }
  var wrong = pageIntegrity(size, 0, 4096, root)
  if wrong.accept(b) || wrong.accept(a) || wrong.verified() { return 37 }
  var changed = vectorLeaf(size, 0, true)
  if !changed.sibling(bcv) || !changed.sibling(cd) || !changed.sibling(ecv)
    || changed.verifies(
      root
    )
  {
    return 38
  }
  if e.sibling(left) || e.verifies(root) { return 39 }
  var badLength = imageChunk(63, 0)
  let msg = BlakeBlock(low: acv, high: bcv)
  if badLength.absorb(msg, 64) || badLength.absorb(msg, 63) { return 40 }
  if !imageChunk(size, 5).failed || !pageIntegrity(size, 1, 4096, root).failed {
    return 41
  }
  let fullRoot = BlakeCv(
    w0: 0x64d6_75f8,
    w1: 0x8589_e26d,
    w2: 0xee34_6f64,
    w3: 0x579a_be13,
    w4: 0xf715_d56f,
    w5: 0x260a_5b6b,
    w6: 0x3547_32bb,
    w7: 0xe4dd_1d04)
  var full = pageIntegrity(16384, 0, 16384, fullRoot)
  for i in 0..<16 {
    var leaf = vectorLeaf(16384, UInt64(i), false)
    var span: UInt64 = 1
    for _ in 0..<4 {
      let neighbor = ((UInt64(i) / span) ^ 1) * span
      if !leaf.sibling(vectorSubtree(neighbor, span)) { return 42 }
      span *= 2
    }
    if !full.accept(leaf) { return 43 }
  }
  if !full.verified() { return 44 }
  return 0
}

// Test-side proof builder, bounded to three internal levels.
func vectorSubtree(_ start: UInt64, _ count: UInt64) -> BlakeCv {
  if count == 1 { return vectorLeaf(16384, start, false).chain }
  let half = count / 2
  return imageParentCv(vectorSubtree(start, half), vectorSubtree(start + half, half))
}
