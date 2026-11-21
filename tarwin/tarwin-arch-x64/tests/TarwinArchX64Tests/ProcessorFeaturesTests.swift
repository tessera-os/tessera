import Testing
import TarwinArchX64

@Test func namedFeaturesRequireEveryCpuidBit() {
  var snapshot = [UInt64](repeating: 0, count: 28)
  snapshot[0] = 13
  snapshot[4] = 0x80000007
  let required = [
    (10, [0, 1, 9, 12, 13, 19, 20, 22, 23, 25, 26, 28, 29, 30]),
    (13, [3, 5, 8, 9, 18]), (14, [7, 9, 10]), (15, [20]), (18, [0, 5]), (24, [0, 1, 2]),
  ]
  for (row, bits) in required {
    for bit in bits { snapshot[row] |= 1 << bit }
  }
  func read(_ words: [UInt64]) -> X64TargetFeatures? {
    words.withUnsafeBufferPointer { X64TargetFeatures($0) }
  }
  #expect(read(snapshot)?.namedBaseline == true)
  for (row, bits) in required {
    for bit in bits {
      var lacking = snapshot
      lacking[row] ^= 1 << bit
      #expect(read(lacking)?.namedBaseline == false)
    }
  }
  #expect(read(snapshot)?.deadlineTimer == false && read(snapshot)?.invariantCounter == false)
  snapshot[10] |= 1 << 24
  snapshot[23] |= 1 << 8
  #expect(read(snapshot)?.deadlineTimer == true && read(snapshot)?.invariantCounter == true)
  #expect(read(Array(snapshot.dropLast())) == nil)
  snapshot[0] = 12
  #expect(read(snapshot) == nil)
  snapshot[0] = 13
  snapshot[4] -= 1
  #expect(read(snapshot) == nil)
}
