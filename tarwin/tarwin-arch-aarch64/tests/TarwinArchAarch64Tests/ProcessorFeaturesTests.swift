import TarwinArchAarch64
import Testing

@Test func registerAdmissionRequiresEveryNamedFeatureAndEL2() throws {
  // Index, low bit, value in one minimal accepted hardware snapshot.
  let fields = [
    (1, 16, 1), (1, 20, 1), (1, 8, 1), (1, 24, 1), (2, 4, 1), (2, 0, 1),
    (3, 16, 1), (3, 20, 2), (3, 28, 1), (3, 44, 1), (3, 52, 2), (4, 4, 1), (4, 20, 2),
    (4, 12, 1), (4, 16, 1), (4, 32, 1), (4, 36, 1), (6, 20, 1), (7, 8, 1), (7, 20, 2), (8, 32, 1),
  ]
  var v = [UInt64](repeating: 0, count: 12)
  v[0] = 8
  v[9] = 62_500_000
  for (i, shift, value) in fields { v[i] |= UInt64(value) << shift }
  func accept(_ raw: [UInt64]) -> Bool {
    raw.withUnsafeBufferPointer { ArmProcessorFeatures($0)?.w0Registers == true }
  }
  #expect(accept(v))
  for (i, shift, _) in fields {
    var missing = v
    missing[i] &= ~(15 << shift)
    #expect(!accept(missing))
    missing[i] |= 15 << shift
    #expect(!accept(missing))
  }
  var el1 = v
  el1[0] = 4
  #expect(!accept(el1))
  var noTimer = v
  noTimer[9] = 0
  #expect(!accept(noTimer))
  #expect(!accept(Array(v.prefix(11))))
}
