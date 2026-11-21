// Unkeyed BLAKE3-256 compression. Based on BLAKE3-team/BLAKE3 1.8.2,
// reference_impl (CC0-1.0). Fixed-size scalar values only: no heap or SIMD.
public struct BlakeCv {
  public let w0: UInt32
  public let w1: UInt32
  public let w2: UInt32
  public let w3: UInt32
  public let w4: UInt32
  public let w5: UInt32
  public let w6: UInt32
  public let w7: UInt32

  public func matches(_ b: BlakeCv) -> Bool {
    return w0 == b.w0 && w1 == b.w1 && w2 == b.w2 && w3 == b.w3 && w4 == b.w4 && w5 == b.w5
      && w6 == b.w6 && w7 == b.w7
  }

  public init(
    w0: UInt32, w1: UInt32, w2: UInt32, w3: UInt32, w4: UInt32, w5: UInt32, w6: UInt32, w7: UInt32
  ) {
    self.w0 = w0
    self.w1 = w1
    self.w2 = w2
    self.w3 = w3
    self.w4 = w4
    self.w5 = w5
    self.w6 = w6
    self.w7 = w7
  }
}

// Sixteen little-endian words read from private, pinned file bytes.
public struct BlakeBlock {
  public let low: BlakeCv
  public let high: BlakeCv

  public init(low: BlakeCv, high: BlakeCv) {
    self.low = low
    self.high = high
  }
}

func initialCv() -> BlakeCv {
  return BlakeCv(
    w0: 0x6a09_e667,
    w1: 0xbb67_ae85,
    w2: 0x3c6e_f372,
    w3: 0xa54f_f53a,
    w4: 0x510e_527f,
    w5: 0x9b05_688c,
    w6: 0x1f83_d9ab,
    w7: 0x5be0_cd19)
}

struct BlakeMix {
  let a: UInt32
  let b: UInt32
  let c: UInt32
  let d: UInt32
}

func addWords(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
  return x &+ y &+ z
}

func rotr32(_ word: UInt32, _ bits: UInt32) -> UInt32 {
  return (word >> bits) | (word << (32 - bits))
}

func blakeMix(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ x: UInt32, _ y: UInt32)
  -> BlakeMix
{
  let a1 = addWords(a, b, x)
  let d1 = rotr32(d ^ a1, 16)
  let c1 = addWords(c, d1, 0)
  let b1 = rotr32(b ^ c1, 12)
  let a2 = addWords(a1, b1, y)
  let d2 = rotr32(d1 ^ a2, 8)
  let c2 = addWords(c1, d2, 0)
  return BlakeMix(a: a2, b: rotr32(b1 ^ c2, 7), c: c2, d: d2)
}

func blakeRound(_ s: BlakeBlock, _ m: BlakeBlock) -> BlakeBlock {
  let c0 = blakeMix(s.low.w0, s.low.w4, s.high.w0, s.high.w4, m.low.w0, m.low.w1)
  let c1 = blakeMix(s.low.w1, s.low.w5, s.high.w1, s.high.w5, m.low.w2, m.low.w3)
  let c2 = blakeMix(s.low.w2, s.low.w6, s.high.w2, s.high.w6, m.low.w4, m.low.w5)
  let c3 = blakeMix(s.low.w3, s.low.w7, s.high.w3, s.high.w7, m.low.w6, m.low.w7)
  let d0 = blakeMix(c0.a, c1.b, c2.c, c3.d, m.high.w0, m.high.w1)
  let d1 = blakeMix(c1.a, c2.b, c3.c, c0.d, m.high.w2, m.high.w3)
  let d2 = blakeMix(c2.a, c3.b, c0.c, c1.d, m.high.w4, m.high.w5)
  let d3 = blakeMix(c3.a, c0.b, c1.c, c2.d, m.high.w6, m.high.w7)
  return BlakeBlock(
    low: BlakeCv(
      w0: d0.a,
      w1: d1.a,
      w2: d2.a,
      w3: d3.a,
      w4: d3.b,
      w5: d0.b,
      w6: d1.b,
      w7: d2.b),
    high: BlakeCv(
      w0: d2.c,
      w1: d3.c,
      w2: d0.c,
      w3: d1.c,
      w4: d1.d,
      w5: d2.d,
      w6: d3.d,
      w7: d0.d))
}

func permuteMessage(_ m: BlakeBlock) -> BlakeBlock {
  return BlakeBlock(
    low: BlakeCv(
      w0: m.low.w2,
      w1: m.low.w6,
      w2: m.low.w3,
      w3: m.high.w2,
      w4: m.low.w7,
      w5: m.low.w0,
      w6: m.low.w4,
      w7: m.high.w5),
    high: BlakeCv(
      w0: m.low.w1,
      w1: m.high.w3,
      w2: m.high.w4,
      w3: m.low.w5,
      w4: m.high.w1,
      w5: m.high.w6,
      w6: m.high.w7,
      w7: m.high.w0))
}

func blakeCompress(
  _ cv: BlakeCv,
  _ message: BlakeBlock,
  _ counter: UInt64,
  _ length: UInt32,
  _ flags: UInt32
) -> BlakeCv {
  let iv = initialCv()
  var state = BlakeBlock(
    low: cv,
    high: BlakeCv(
      w0: iv.w0,
      w1: iv.w1,
      w2: iv.w2,
      w3: iv.w3,
      w4: UInt32(counter & 0xffff_ffff),
      w5: UInt32(counter >> 32),
      w6: length,
      w7: flags))
  var schedule = BlakeBlock(low: message.low, high: message.high)
  for round in 0..<7 {
    state = blakeRound(state, schedule)
    if round < 6 { schedule = permuteMessage(schedule) }
  }
  return BlakeCv(
    w0: state.low.w0 ^ state.high.w0,
    w1: state.low.w1 ^ state.high.w1,
    w2: state.low.w2 ^ state.high.w2,
    w3: state.low.w3 ^ state.high.w3,
    w4: state.low.w4 ^ state.high.w4,
    w5: state.low.w5 ^ state.high.w5,
    w6: state.low.w6 ^ state.high.w6,
    w7: state.low.w7 ^ state.high.w7)
}
