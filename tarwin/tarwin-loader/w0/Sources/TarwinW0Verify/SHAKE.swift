// FIPS 202, Keccak-f[1600], SHAKE128 and SHAKE256. Byte offsets in a lane
// are little-endian on every host; no native-endian reads or unaligned casts.
private let rounds: InlineArray<24, UInt64> = [
  0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808a, 0x8000_0000_8000_8000,
  0x0000_0000_0000_808b, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
  0x0000_0000_0000_008a, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000a,
  0x0000_0000_8000_808b, 0x8000_0000_0000_008b, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
  0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800a, 0x8000_0000_8000_000a,
  0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
]
private let rotation: InlineArray<25, Int> = [
  0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14,
]
private func rol(_ x: UInt64, _ n: Int) -> UInt64 { (x << n) | (x >> (64 - n)) }
struct Shake {
  let rate: Int
  private var s = InlineArray<25, UInt64>(repeating: 0)
  private var pos = 0
  init(_ bits: Int) { rate = bits == 128 ? 168 : 136 }
  private mutating func permute() {
    for r in 0..<24 {
      var c = InlineArray<5, UInt64>(repeating: 0)
      for x in 0..<5 { c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20] }
      var b = InlineArray<25, UInt64>(repeating: 0)
      for x in 0..<5 {
        let d = c[(x + 4) % 5] ^ rol(c[(x + 1) % 5], 1)
        for y in 0..<5 {
          let i = x + 5 * y
          b[y + 5 * ((2 * x + 3 * y) % 5)] = rol(s[i] ^ d, rotation[i])
        }
      }
      for y in 0..<5 {
        for x in 0..<5 {
          s[5 * y + x] = b[5 * y + x] ^ ((~b[5 * y + (x + 1) % 5]) & b[5 * y + (x + 2) % 5])
        }
      }
      s[0] ^= rounds[r]
    }
  }
  mutating func put(_ byte: UInt8) {
    s[pos >> 3] ^= UInt64(byte) << (8 * (pos & 7))
    pos += 1
    if pos == rate {
      permute()
      pos = 0
    }
  }
  mutating func absorb(_ bytes: UnsafeRawBufferPointer) { for b in bytes { put(b) } }
  mutating func finish() {
    s[pos >> 3] ^= UInt64(31) << (8 * (pos & 7))
    s[rate / 8 - 1] ^= 1 << 63
    permute()
    pos = 0
  }
  mutating func byte() -> UInt8 {
    if pos == rate {
      permute()
      pos = 0
    }
    let result = UInt8(truncatingIfNeeded: s[pos >> 3] >> (8 * (pos & 7)))
    pos += 1
    return result
  }
}
