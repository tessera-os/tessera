// Verification-only port of the public-domain TweetNaCl Edwards formulas
// (20140427). No secret operands. Reject noncanonical encodings and require
// the enrolled key to be a nonidentity point in the prime-order subgroup.
private typealias Limbs = InlineArray<16, Int64>
private struct Field {
  var v = Limbs(repeating: 0)
  init() {}
  init(_ a: Limbs) { v = a }
  static let one = Field([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
  static let
    d = Field([
      0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079,
      0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203,
    ]),
    d2 = Field([
      0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2,
      0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406,
    ])
  static let sqrtMinusOne = Field([
    0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d,
    0xdf0b, 0x4fc1, 0x2480, 0x2b83,
  ])
  mutating func carry() {
    for i in 0..<16 {
      let c = v[i] >> 16
      v[i] -= c << 16
      if i == 15 { v[0] += 38 * c } else { v[i + 1] += c }
    }
  }
  static func + (_ a: Field, _ b: Field) -> Field {
    var r = Field()
    for i in 0..<16 { r.v[i] = a.v[i] + b.v[i] }
    return r
  }
  static func - (_ a: Field, _ b: Field) -> Field {
    var r = Field()
    for i in 0..<16 { r.v[i] = a.v[i] - b.v[i] }
    return r
  }
  static func * (_ a: Field, _ b: Field) -> Field {
    var t = InlineArray<31, Int64>(repeating: 0)
    for i in 0..<16 { for j in 0..<16 { t[i + j] += a.v[i] * b.v[j] } }
    var r = Field()
    for i in 0..<15 { r.v[i] = t[i] + 38 * t[i + 16] }
    r.v[15] = t[15]
    r.carry()
    r.carry()
    return r
  }
  func normalized() -> Field {
    var t = self
    t.carry()
    t.carry()
    t.carry()
    for _ in 0..<2 {
      var m = Field()
      m.v[0] = t.v[0] - 0xffed
      for i in 1..<16 {
        m.v[i] = t.v[i] - (i == 15 ? 0x7fff : 0xffff) - ((m.v[i - 1] >> 16) & 1)
        m.v[i - 1] &= 0xffff
      }
      if m.v[15] >= 0 { t = m }
    }
    return t
  }
  func same(_ y: Field) -> Bool {
    let a = normalized()
    let b = y.normalized()
    for i in 0..<16 where a.v[i] != b.v[i] { return false }
    return true
  }
  func pow2523() -> Field {
    var c = self
    for i in stride(from: 250, through: 0, by: -1) {
      c = c * c
      if i != 1 { c = c * self }
    }
    return c
  }
}
private let order: InlineArray<32, UInt8> = [
  0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
]
private struct Point {
  var x: Field, y: Field, z: Field, t: Field
  // No lazy global storage in the measured R/RX-only kernel.
  static var identity: Point { Point(x: Field(), y: .one, z: .one, t: Field()) }
  static var base: Point {
    let x = Field([
      0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231,
      0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169,
    ])
    let y = Field([
      0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
      0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
    ])
    return Point(x: x, y: y, z: .one, t: x * y)
  }
  func add(_ q: Point) -> Point {
    let a = (y - x) * (q.y - q.x)
    let b = (y + x) * (q.y + q.x)
    let c = t * q.t * Field.d2
    let zz = z * q.z
    let d = zz + zz
    let e = b - a
    let f = d - c
    let g = d + c
    let h = b + a
    return Point(x: e * f, y: h * g, z: g * f, t: e * h)
  }
  func times(_ scalar: UnsafeRawBufferPointer) -> Point {
    var p = Point.identity
    for i in stride(from: scalar.count * 8 - 1, through: 0, by: -1) {
      p = p.add(p)
      if scalar[i >> 3] & (1 << (i & 7)) != 0 { p = p.add(self) }
    }
    return p
  }
  func same(_ q: Point) -> Bool { (x * q.z).same(q.x * z) && (y * q.z).same(q.y * z) }
  static func decode(_ b: UnsafeRawBufferPointer) -> Point? {
    guard b.count == 32 else { return nil }
    var y = Field()
    for i in 0..<16 { y.v[i] = Int64(b[2 * i]) + (Int64(b[2 * i + 1]) << 8) }
    y.v[15] &= 0x7fff
    let cy = y.normalized()
    for i in 0..<16 where y.v[i] != cy.v[i] { return nil }
    let num = y * y - Field.one
    let den = y * y * Field.d + Field.one
    let den2 = den * den
    let den4 = den2 * den2
    let den6 = den4 * den2
    var x = (den6 * num * den).pow2523() * num * den2 * den
    if !(x * x * den).same(num) { x = x * Field.sqrtMinusOne }
    guard (x * x * den).same(num) else { return nil }
    let sign = Int64(b[31] >> 7)
    if x.normalized().v[0] & 1 != sign {
      if x.same(Field()) { return nil }
      x = Field() - x
    }
    return Point(x: x, y: y, z: .one, t: x * y)
  }
}
func verifyEd25519(
  key: UnsafeRawBufferPointer, message: UnsafeRawBufferPointer, signature: UnsafeRawBufferPointer
) -> Bool {
  guard signature.count == 64, key.count == 32, message.count <= 65536 else { return false }
  let rbytes = UnsafeRawBufferPointer(rebasing: signature[..<32])
  let s = UnsafeRawBufferPointer(rebasing: signature[32...])
  var below = false
  for i in stride(from: 31, through: 0, by: -1) where s[i] != order[i] {
    below = s[i] < order[i]
    break
  }
  guard below, let a = Point.decode(key), !a.same(.identity), let r = Point.decode(rbytes),
    withUnsafeBytes(of: order, { a.times($0).same(.identity) })
  else { return false }
  var sha = SHA512()
  for b in rbytes { sha.put(b) }
  for b in key { sha.put(b) }
  for b in message { sha.put(b) }
  let h = sha.finish()
  return withUnsafeBytes(of: h) { Point.base.times(s).same(r.add(a.times($0))) }
}
