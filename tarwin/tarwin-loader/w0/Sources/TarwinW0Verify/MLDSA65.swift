// FIPS 204 ML-DSA-65.Verify, pure mode. All operands are public.
// The eight caller-owned polynomials hold five z hats, the challenge,
// one row accumulator and the current public-key row, not a 6x5 matrix.
private let q: Int64 = 8_380_417
// 1753^BitRev8(i) mod q, in ordinary (not Montgomery) representation.
private let roots: InlineArray<256, Int32> = [
  1, 4_808_194, 3_765_607, 3_761_513, 5_178_923, 5_496_691, 5_234_739, 5_178_987, 7_778_734,
  3_542_485, 2_682_288, 2_129_892, 3_764_867, 7_375_178, 557458, 7_159_240, 5_010_068, 4_317_364,
  2_663_378, 6_705_802, 4_855_975, 7_946_292, 676590, 7_044_481, 5_152_541, 1_714_295, 2_453_983,
  1_460_718, 7_737_789, 4_795_319, 2_815_639, 2_283_733, 3_602_218, 3_182_878, 2_740_543, 4_793_971,
  5_269_599, 2_101_410, 3_704_823, 1_159_875, 394148, 928749, 1_095_468, 4_874_037, 2_071_829,
  4_361_428, 3_241_972, 2_156_050, 3_415_069, 1_759_347, 7_562_881, 4_805_951, 3_756_790, 6_444_618,
  6_663_429, 4_430_364, 5_483_103, 3_192_354, 556856, 3_870_317, 2_917_338, 1_853_806, 3_345_963,
  1_858_416, 3_073_009, 1_277_625, 5_744_944, 3_852_015, 4_183_372, 5_157_610, 5_258_977, 8_106_357,
  2_508_980, 2_028_118, 1_937_570, 4_564_692, 2_811_291, 5_396_636, 7_270_901, 4_158_088, 1_528_066,
  482649, 1_148_858, 5_418_153, 7_814_814, 169688, 2_462_444, 5_046_034, 4_213_992, 4_892_034,
  1_987_814, 5_183_169, 1_736_313, 235407, 5_130_263, 3_258_457, 5_801_164, 1_787_943, 5_989_328,
  6_125_690, 3_482_206, 4_197_502, 7_080_401, 6_018_354, 7_062_739, 2_461_387, 3_035_980, 621164,
  3_901_472, 7_153_756, 2_925_816, 3_374_250, 1_356_448, 5_604_662, 2_683_270, 5_601_629, 4_912_752,
  2_312_838, 7_727_142, 7_921_254, 348812, 8_052_569, 1_011_223, 6_026_202, 4_561_790, 6_458_164,
  6_143_691, 1_744_507, 1753, 6_444_997, 5_720_892, 6_924_527, 2_660_408, 6_600_190, 8_321_269,
  2_772_600, 1_182_243, 87208, 636927, 4_415_111, 4_423_672, 6_084_020, 5_095_502, 4_663_471,
  8_352_605, 822541, 1_009_365, 5_926_272, 6_400_920, 1_596_822, 4_423_473, 4_620_952, 6_695_264,
  4_969_849, 2_678_278, 4_611_469, 4_829_411, 635956, 8_129_971, 5_925_040, 4_234_153, 6_607_829,
  2_192_938, 6_653_329, 2_387_513, 4_768_667, 8_111_961, 5_199_961, 3_747_250, 2_296_099, 1_239_911,
  4_541_938, 3_195_676, 2_642_980, 1_254_190, 8_368_000, 2_998_219, 141835, 8_291_116, 2_513_018,
  7_025_525, 613238, 7_070_156, 6_161_950, 7_921_677, 6_458_423, 4_040_196, 4_908_348, 2_039_144,
  6_500_539, 7_561_656, 6_201_452, 6_757_063, 2_105_286, 6_006_015, 6_346_610, 586241, 7_200_804,
  527981, 5_637_006, 6_903_432, 1_994_046, 2_491_325, 6_987_258, 507927, 7_192_532, 7_655_613,
  6_545_891, 5_346_675, 8_041_997, 2_647_994, 3_009_748, 5_767_564, 4_148_469, 749577, 4_357_667,
  3_980_599, 2_569_011, 6_764_887, 1_723_229, 1_665_318, 2_028_038, 1_163_598, 5_011_144, 3_994_671,
  8_368_538, 7_009_900, 3_020_393, 3_363_542, 214880, 545376, 7_609_976, 3_105_558, 7_277_073,
  508145, 7_826_699, 860144, 3_430_436, 140244, 6_866_265, 6_195_333, 3_123_762, 2_358_373,
  6_187_330, 5_365_997, 6_663_603, 2_926_054, 7_987_710, 8_077_412, 3_531_229, 4_405_932, 4_606_686,
  1_900_052, 7_598_542, 1_054_478, 7_648_983,
]
private func mod(_ n: Int64) -> Int32 {
  let a = n % q
  return Int32(a < 0 ? a + q : a)
}
private func transform(_ a: UnsafeMutablePointer<Int32>, inverse: Bool) {
  var width = inverse ? 1 : 128
  var idx = inverse ? 256 : 0
  while width >= 1 && width <= 128 {
    for base in stride(from: 0, to: 256, by: 2 * width) {
      idx += inverse ? -1 : 1
      let root = Int64(roots[idx])
      for j in base..<base + width {
        let x = Int64(a[j])
        let y = Int64(a[j + width])
        if inverse {
          a[j] = mod(x + y)
          a[j + width] = mod((y - x) * root)
        } else {
          let t = Int64(mod(root * y))
          a[j] = mod(x + t)
          a[j + width] = mod(x - t)
        }
      }
    }
    width = inverse ? width * 2 : width / 2
  }
  // 256^-1 mod q.
  if inverse { for i in 0..<256 { a[i] = mod(Int64(a[i]) * 8_347_681) } }
}
private struct Bits {
  var pos: Int, acc: UInt32 = 0, bits = 0
  mutating func take(_ n: Int, _ input: UnsafeRawBufferPointer) -> Int32 {
    while bits < n {
      acc |= UInt32(input[pos]) << bits
      pos += 1
      bits += 8
    }
    let out = acc & ((1 << n) - 1)
    acc >>= n
    bits -= n
    return Int32(out)
  }
}
func verifyMLDSA65(
  key: UnsafeRawBufferPointer, message: UnsafeRawBufferPointer, context: UnsafeRawBufferPointer,
  signature: UnsafeRawBufferPointer, work: UnsafeMutableBufferPointer<Int32>
) -> Bool {
  guard key.count == 1952, signature.count == 3309, context.count <= 255, message.count <= 65536,
    work.count >= 2048, let z = work.baseAddress
  else { return false }
  let c = z + 1280
  let w = c + 256
  let t = w + 256
  let hints = 48 + 5 * 640
  var used = 0
  for row in 0..<6 {
    let end = Int(signature[hints + 55 + row])
    guard end >= used, end <= 55 else { return false }
    for i in used..<end where i > used && signature[hints + i] <= signature[hints + i - 1] {
      return false
    }
    used = end
  }
  for i in used..<55 where signature[hints + i] != 0 { return false }
  var bits = Bits(pos: 48)
  for col in 0..<5 {
    let poly = z + col * 256
    for i in 0..<256 {
      let value = 524288 - bits.take(20, signature)
      guard abs(value) < 524288 - 196 else { return false }
      poly[i] = value
    }
    transform(poly, inverse: false)
  }
  var challenge = Shake(256)
  challenge.absorb(.init(rebasing: signature[..<48]))
  challenge.finish()
  var signs: UInt64 = 0
  for i in 0..<8 { signs |= UInt64(challenge.byte()) << (8 * i) }
  for i in 0..<256 { c[i] = 0 }
  for i in 207..<256 {
    var j = Int(challenge.byte())
    while j > i { j = Int(challenge.byte()) }
    c[i] = c[j]
    c[j] = signs & 1 == 0 ? 1 : -1
    signs >>= 1
  }
  transform(c, inverse: false)
  var tr = Shake(256)
  tr.absorb(key)
  tr.finish()
  var mu = Shake(256)
  for _ in 0..<64 { mu.put(tr.byte()) }
  mu.put(0)
  mu.put(UInt8(context.count))
  mu.absorb(context)
  mu.absorb(message)
  mu.finish()
  var check = Shake(256)
  for _ in 0..<64 { check.put(mu.byte()) }
  var packed = Bits(pos: 32)
  used = 0
  for row in 0..<6 {
    for i in 0..<256 {
      w[i] = 0
      t[i] = packed.take(10, key) << 13
    }
    transform(t, inverse: false)
    for col in 0..<5 {
      var stream = Shake(128)
      stream.absorb(.init(rebasing: key[..<32]))
      stream.put(UInt8(col))
      stream.put(UInt8(row))
      stream.finish()
      let poly = z + col * 256
      var i = 0
      while i < 256 {
        let lo = Int64(stream.byte())
        let mid = Int64(stream.byte())
        let hi = Int64(stream.byte() & 127)
        let a = lo | (mid << 8) | (hi << 16)
        if a < q {
          w[i] = mod(Int64(w[i]) + a * Int64(poly[i]))
          i += 1
        }
      }
    }
    for i in 0..<256 { w[i] = mod(Int64(w[i]) - Int64(c[i]) * Int64(t[i])) }
    transform(w, inverse: true)
    let end = Int(signature[hints + 55 + row])
    var low: UInt8 = 0
    for i in 0..<256 {
      let a = Int64(w[i])
      var high = (((a + 127) >> 7) * 1025 + (1 << 21)) >> 22
      high &= 15
      if used < end && Int(signature[hints + used]) == i {
        var part = a - high * ((q - 1) / 16)
        if part > (q - 1) / 2 { part -= q }
        high = (high + (part > 0 ? 1 : -1)) & 15
        used += 1
      }
      if i & 1 == 0 { low = UInt8(high) } else { check.put(low | (UInt8(high) << 4)) }
    }
  }
  check.finish()
  for i in 0..<48 where check.byte() != signature[i] { return false }
  return true
}
