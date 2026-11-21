import Testing

@testable import Tarboot

#if arch(arm64) || arch(riscv64)
  @Test func requireProvisionedCounterNotOrdinaryNvram() {
    let digest = (0..<32).map(UInt8.init)
    var b: [UInt8] =
      [
        128, 1, 0, 0, 0, 62, 0, 0, 0, 0, 0, 14, 1, 128, 240, 1, 0, 11, 98, 4, 0, 17, 0, 0, 0, 8, 0,
        34, 0, 11,
      ] + digest
    func valid() -> Bool {
      b.withUnsafeBytes { response in
        digest.withUnsafeBytes { counterPublic(response, index: 0x0180_f001, name: $0) }
      }
    }
    #expect(valid())
    for at in [0, 5, 9, 11, 12, 17, 18, 19, 20, 21, 23, 25, 27, 29, 30, 61] {
      b[at] ^= 1
      #expect(!valid())
      b[at] ^= 1
    }
    b.removeLast()
    #expect(!valid())
  }

  @Test func readExactCounterValueOrFailClosed() {
    var b: [UInt8] = [
      128, 2, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 1, 0, 0,
    ]
    #expect(b.withUnsafeBytes(counterValue) == 0x0102_0304_0506_0708)
    for at in [0, 5, 9, 13, 15, 25, 26, 28] {
      b[at] ^= 2
      #expect(b.withUnsafeBytes(counterValue) == nil)
      b[at] ^= 2
    }
    b.append(0)
    #expect(b.withUnsafeBytes(counterValue) == nil)
  }
#endif
