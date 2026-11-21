/// Checks the complete TVISA §30 named feature closure and vector mode of
/// the unmodified W0 baseline. Hardware support is a separate guest check.
public func matchesW0Baseline(_ descriptor: UnsafeRawBufferPointer, machine: UInt16) -> Bool {
  let target: StaticString
  let features: StaticString
  let scale: UInt8
  switch machine {
  case ElfMachine.aarch64:
    target = "aarch64.base"
    scale = 1
    features =
      "bti crc dotprod fcma flagm flagm2 fp16 frintts jscvt lse lse2 pauth rcpc rcpc2 rdm sb ssbs"
  case ElfMachine.x64:
    target = "x64.v3"
    scale = 2
    features =
      "aes avx avx2 bmi1 bmi2 cx16 erms f16c fma ibt lahf_sahf lzcnt movbe pclmul popcnt rdrand rdseed shstk sse3 sse4_1 sse4_2 ssse3 vaes vpclmulqdq xsave"
  case ElfMachine.rv64:
    target = "rv64.base"
    scale = 0
    features =
      "supm v zawrs zba zbb zbs zcb zcmop zfa zfhmin zicbom zicbop zicboz zicfilp zicfiss zicond zihintntl zihintpause zimop zvbb zvfhmin zvkt"
  default: return false
  }
  let reader = ELFReader(bytes: descriptor)
  var cursor = WireCursor(reader: reader, pos: 0, end: descriptor.count)
  guard let name = cursor.text(), reader.nameEquals(name, target), let start = cursor.take(2) else {
    return false
  }
  var from = 0
  var parsed = 0
  for end in 0...features.utf8CodeUnitCount
  where end == features.utf8CodeUnitCount || features.utf8Start[end] == 32 {
    guard let field = cursor.text(), field.count == end - from else { return false }
    for i in 0..<field.count where descriptor[field.lowerBound + i] != features.utf8Start[from + i]
    { return false }
    from = end + 1
    parsed += 1
  }
  guard parsed == Int(reader.u16(start)), let s = cursor.take(2), cursor.pos == cursor.end else {
    return false
  }
  return descriptor[s] == (scale == 0 ? 0 : 1) && descriptor[s + 1] == scale
}
