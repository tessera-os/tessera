func hex(_ s: String) -> [UInt8] {
  let ascii = Array(s.utf8)
  func nibble(_ x: UInt8) -> UInt8 { x > 57 ? x - 87 : x - 48 }
  return stride(from: 0, to: ascii.count, by: 2).map {
    nibble(ascii[$0]) << 4 | nibble(ascii[$0 + 1])
  }
}

private func put(_ b: inout [UInt8], _ at: Int, _ size: Int, _ value: Int) {
  for i in 0..<size { b[at + i] = UInt8(truncatingIfNeeded: UInt64(value) >> (i * 8)) }
}

func archive(target: Int = 183) -> [UInt8] {
  var k = (0..<3501).map { $0 < 512 ? 0 : UInt8($0 % 251) }
  k[0..<7] = [0x7f, 69, 76, 70, 2, 1, 1]
  for (at, width, value) in [
    (16, 2, 3), (18, 2, target), (20, 4, 1), (24, 8, 0x4080), (32, 8, 64), (52, 2, 64),
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
  switch target {
  case 183: b += hex("d6d2f06a07f83cedb93e2b5be8841e3b61dd530d4b12a5e0fe6b068aa6d9a94f")
  case 62: b += hex("d52459d614edd057da446a8f032a50ae47c5d51be05f37ec22640a1d83601931")
  case 243: b += hex("1b8496bbf87be4a29c2cf23b3c60a9c5738f9ff7ce87e64fbc81d1d7566e2554")
  default: preconditionFailure("unknown fixture architecture")
  }
  return b
}
