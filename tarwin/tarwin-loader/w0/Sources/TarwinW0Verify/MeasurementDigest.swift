/// Expected SHA-256 bank value after one extend. Both inputs are digest
/// bytes in TPM wire order. This neither reads nor alters a PCR.
public func replaySHA256PCR(previous: InlineArray<32, UInt8>, event: InlineArray<32, UInt8>)
  -> InlineArray<32, UInt8>
{
  var block = InlineArray<64, UInt8>(repeating: 0)
  for i in 0..<32 {
    block[i] = previous[i]
    block[32 + i] = event[i]
  }
  return withUnsafeBytes(of: &block) { measurementDigest($0) }
}

/// Hash the exact retained archive or configuration bytes, up to 1 MiB.
/// A digest is an event input, not signature verification or a live PCR value.
public func firmwareMeasurementSHA256(_ bytes: UnsafeRawBufferPointer) -> InlineArray<32, UInt8>? {
  guard (1...(1 << 20)).contains(bytes.count) else { return nil }
  return measurementDigest(bytes)
}

/// SHA-256, FIPS 180-4. The SHA-256 constants are the high halves of the
/// first 64 SHA-512 constants. W1 input sizes are bounded by archive authorization.
func measurementDigest(_ bytes: UnsafeRawBufferPointer) -> InlineArray<32, UInt8> {
  func rr(_ w: UInt32, _ n: Int) -> UInt32 { (w >> n) | (w << (32 - n)) }
  var state: InlineArray<8, UInt32> = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
    0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
  ]
  let end = (bytes.count + 72) & ~63
  let bits = UInt64(bytes.count) << 3
  var w = InlineArray<16, UInt32>(repeating: 0)
  for base in stride(from: 0, to: end, by: 64) {
    for j in 0..<64 {
      let at = base + j
      let byte: UInt8
      if at < bytes.count {
        byte = bytes[at]
      } else if at == bytes.count {
        byte = 0x80
      } else if at >= end - 8 {
        byte = UInt8(truncatingIfNeeded: bits >> (8 * (end - 1 - at)))
      } else {
        byte = 0
      }
      w[j >> 2] = (w[j >> 2] << 8) | UInt32(byte)
    }
    var a = state[0]
    var b = state[1]
    var c = state[2]
    var d = state[3]
    var e = state[4]
    var f = state[5]
    var g = state[6]
    var h = state[7]
    for i in 0..<64 {
      let j = i & 15
      if i >= 16 {
        let x = w[(j + 1) & 15]
        let y = w[(j + 14) & 15]
        w[j] =
          w[j] &+ (rr(x, 7) ^ rr(x, 18) ^ (x >> 3)) &+ w[(j + 9) & 15]
          &+ (rr(y, 17) ^ rr(y, 19) ^ (y >> 10))
      }
      let t =
        h &+ (rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)) &+ ((e & f) ^ (~e & g))
        &+ UInt32(roundConstants[i] >> 32) &+ w[j]
      let u = (rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
      h = g
      g = f
      f = e
      e = d &+ t
      d = c
      c = b
      b = a
      a = t &+ u
    }
    state[0] &+= a
    state[1] &+= b
    state[2] &+= c
    state[3] &+= d
    state[4] &+= e
    state[5] &+= f
    state[6] &+= g
    state[7] &+= h
  }
  var result = InlineArray<32, UInt8>(repeating: 0)
  for i in 0..<32 { result[i] = UInt8(truncatingIfNeeded: state[i >> 2] >> (24 - 8 * (i & 3))) }
  return result
}
