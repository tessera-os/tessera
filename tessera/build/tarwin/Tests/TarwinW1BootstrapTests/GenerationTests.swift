import Tarboot
import TarwinRandomCore
import TarwinW1Generation
import Testing

private struct Config: QEMUConfigReader {
  let dma: Bool
  var key: UInt16 = 0, i = 0
  mutating func select(_ key: UInt16) { self.key = key; i = 0 }
  mutating func readByte() -> UInt8 {
    defer { i += 1 }
    switch key {
    case 0: return Array("QEMU".utf8)[i]
    case 1: return i == 0 ? (dma ? 3 : 1) : 0
    case 0x19:
      // One unrelated, well-formed directory entry.
      switch i { case 3, 7: return 1; case 9: return 32; case 12: return 65; default: return 0 }
    default: return 0
    }
  }
}

@Test func registerGenerationRequiresReadOnlyMachineAndStableVersion() {
  let base = W1GenerationSource.registerBase
  let magic: UInt64 = 0x3144_4947_4d56_5754
  func open(_ dma: Bool = false, _ signature: UInt64 = 0x3144_4947_4d56_5754) -> W1GenerationSource? {
    var config = Config(dma: dma)
    return W1GenerationSource(policy: .readOnlyVirt11, reader: &config, regions: .init(start: nil, count: 0)) {
      switch $0 - base { case 0: return signature; case 8: return 1; case 16: return 9; case 24: return 17; default: return nil }
    }
  }
  #expect(open(true) == nil)
  #expect(open(false, magic ^ 1) == nil)
  guard let source = open() else { Issue.record("missing read-only source"); return }
  func sample(_ versions: [UInt64?], _ lo: UInt64?, _ hi: UInt64?) -> RandomEpoch? {
    var i = 0
    return source.current {
      switch $0 - base {
      case 8:
        defer { i += 1 }
        return i < versions.count ? versions[i] : nil
      case 16: return lo
      case 24: return hi
      default: return nil
      }
    }
  }
  #expect(sample([1,2,2,2], 9, 17) == .virtualMachine(low: 9, high: 17))
  #expect(sample([1,2,3,4,5,6,7,7], 9, 17) == nil)
  #expect(sample([1,1], 0, 0) == nil)
  #expect(sample([1,nil], 9, 17) == nil)
  #expect(sample([0,0], 9, 17) == nil)
  #expect(sample([1,1], nil, 17) == nil)
}
