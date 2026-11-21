import TarwinArchX64
import Testing

private struct Registers: X64DeadlineRegisters {
  var masked = true, base: UInt64 = 0xc00, svr: UInt64 = 0x1ff, lvt: UInt64 = 0x40040
  var accesses = 0, writes: [UInt64] = []
  mutating func interruptsMasked() -> Bool { accesses += 1; return masked }
  mutating func apicBase() -> UInt64 { accesses += 1; return base }
  mutating func spuriousVector() -> UInt64 { accesses += 1; return svr }
  mutating func timerLVT() -> UInt64 { accesses += 1; return lvt }
  mutating func setDeadline(_ tsc: UInt64) { writes.append(tsc) }
}

@Test func tscDeadlineGatesAndDisarm() throws {
  var words = [UInt64](repeating: 0, count: 28)
  words[0] = 13
  words[4] = 0x80000007
  let required = [(10,21),(10,24),(11,4),(11,5),(11,9),(23,8)]
  for (word,bit) in required { words[word] |= 1 << bit }
  func features(_ w: [UInt64]) throws -> X64TargetFeatures {
    try #require(w.withUnsafeBufferPointer { X64TargetFeatures($0) })
  }
  let good = try features(words)
  var port = Registers()
  for (word,bit) in required {
    var missing = words
    missing[word] ^= 1 << bit
    let f = try features(missing)
    #expect(!applyX64Deadline(9, features: f, vector: 64, registers: &port))
  }
  #expect(!applyX64Deadline(0, features: good, vector: 64, registers: &port))
  #expect(!applyX64Deadline(1, features: good, vector: 31, registers: &port))
  #expect(port.accesses == 0)
  for variant in 0..<6 {
    var bad = Registers()
    switch variant {
    case 0: bad.masked = false
    case 1: bad.base = 0x800
    case 2: bad.svr = 255
    case 3: bad.lvt |= 1 << 16
    case 4: bad.lvt ^= 1
    default: bad.lvt = 0x20040
    }
    #expect(!applyX64Deadline(nil, features: good, vector: 64, registers: &bad))
    #expect(bad.writes.isEmpty)
  }
  #expect(applyX64Deadline(7, features: good, vector: 64, registers: &port))
  #expect(applyX64Deadline(nil, features: good, vector: 64, registers: &port))
  #expect(port.writes == [7, 0])
}
