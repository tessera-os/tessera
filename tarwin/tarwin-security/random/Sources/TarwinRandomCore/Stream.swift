/// RFC 8439 section 2.3. Little-endian key words, 32-bit counter and 96-bit nonce.
func chachaBlock(
  _ k: InlineArray<8, UInt32>, _ counter: UInt32, _ n0: UInt32, _ n1: UInt32, _ n2: UInt32
)
  -> InlineArray<16, UInt32>
{
  let start: InlineArray<16, UInt32> = [
    0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574,
    k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7], counter, n0, n1, n2,
  ]
  var x = start
  func rol(_ n: UInt32, _ r: Int) -> UInt32 { n << r | n >> (32 - r) }
  func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
    x[a] &+= x[b]
    x[d] = rol(x[d] ^ x[a], 16)
    x[c] &+= x[d]
    x[b] = rol(x[b] ^ x[c], 12)
    x[a] &+= x[b]
    x[d] = rol(x[d] ^ x[a], 8)
    x[c] &+= x[d]
    x[b] = rol(x[b] ^ x[c], 7)
  }
  for _ in 0..<10 {
    qr(0, 4, 8, 12)
    qr(1, 5, 9, 13)
    qr(2, 6, 10, 14)
    qr(3, 7, 11, 15)
    qr(0, 5, 10, 15)
    qr(1, 6, 11, 12)
    qr(2, 7, 8, 13)
    qr(3, 4, 9, 14)
  }
  for i in 0..<16 { x[i] &+= start[i] }
  return x
}

/// Secret, exclusively owned state. Each block replaces the key with its
/// first half; only the second half is returned. Never share across threads.
public struct ChaChaStream: ~Copyable {
  private var key: InlineArray<8, UInt32>
  public init(keyWords: InlineArray<8, UInt32>) { key = keyWords }
  public init?(seed: UnsafeRawBufferPointer) {
    guard seed.count == 32 else { return nil }
    key = .init(repeating: 0)
    for i in 0..<8 {
      key[i] = UInt32(littleEndian: seed.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))
    }
  }
  public mutating func fill(_ output: UnsafeMutableRawBufferPointer) {
    var pos = 0
    while pos < output.count {
      let block = chachaBlock(key, 0, 0, 0, 0)
      for i in 0..<8 { key[i] = block[i] }
      let n = min(32, output.count - pos)
      for i in 0..<n {
        output[pos + i] = UInt8(truncatingIfNeeded: block[8 + i / 4] >> (8 * (i % 4)))
      }
      pos += n
    }
  }
}
