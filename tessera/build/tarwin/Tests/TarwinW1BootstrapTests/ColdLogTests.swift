import TarwinBoot
import CryptoKit
import Testing
@testable import TarwinW1Bootstrap

@Test func coldLogOnlyClaimsSeparateConventionalRAMAfterCheckingTheWholeMap() {
  var b = emptyBootInfo()
  b.mapCount = 3
  b.logAddress = 0x40f0_0000
  b.logSize = 4097
  let held: UInt64 = 8 << 32 | 1
  let ram: UInt64 = 8 << 32
  var words: [UInt64] = [0x4000_1000, 0x20000, ram, 0, b.logAddress, 0x3000, held, 0,
    0x4400_0000, 0x4000, held, 0]
  func selected() -> W1ColdLogLayout? { words.withUnsafeBytes { W1ColdLogLayout(boot: b, map: $0) } }
  #expect(selected()?.storage == 0x4000_4000..<0x4000_8000)
  #expect(selected()?.source == b.logAddress..<b.logAddress+b.logSize)
  for (i, value): (Int, UInt64) in [(0, 0x2100_0000), (1, 0x3000), (2, held), (2, 0),
    (2, ram | (0x20000 << 32)), (6, ram), (6, 7), (8, b.logAddress), (11, 1)] {
    let old = words[i]
    words[i] = value
    #expect(selected() == nil)
    words[i] = old
  }
  b.logSize = 0
  #expect(selected() == nil)
  b.logSize = 0x3001
  #expect(selected() == nil)
}

@Test func coldLogAndPrivatePagesMustFitOneDisjointConventionalRun() {
  var b = emptyBootInfo()
  b.logSize = 16384
  b.logAddress = 0x4000_0000
  b.mapCount = 4
  let ram: UInt64 = 8 << 32
  // Log plus Event2 append space requires two 16 KiB pages. Neither of
  // the smaller runs alone can also hold the requested private frames.
  let words: [UInt64] = [b.logAddress, 0x4000, ram | 1, 0,
    0x4000_4000, 0x8000, ram, 0, 0x4001_0000, 0xc000, ram, 0,
    0x5fff_0000, 0x10000, ram, 0]
  func selected(_ n: UInt64) -> W1ColdLogLayout? {
    words.withUnsafeBytes { W1ColdLogLayout(boot: b, map: $0, privateBytes: n) }
  }
  #expect(selected(0x8000)?.storage == 0x5fff_0000..<0x5fff_8000)
  #expect(selected(0x8000)?.privatePages == 0x5fff_8000..<0x6000_0000)
  for n: UInt64 in [1, 0x1000, 0xc000, (32 << 20) + 16384, .max] {
    #expect(selected(n) == nil)
  }
}

@Test func coldInitRequiresAnIntactPrefixWithoutAnyPCR10Record() {
  func le(_ x: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: x >> ($0 * 8)) } }
  let spec = Array("Spec ID Event03".utf8) + [0] + le(0) + [0, 2, 0, 2] + le(1) + [11,0,32,0,0]
  let header = le(0) + le(3) + [UInt8](repeating: 0, count: 20) + le(UInt32(spec.count)) + spec
  func event(_ pcr: UInt32, _ label: String, _ digest: UInt8, type: UInt32 = 13) -> [UInt8] {
    let head = le(pcr) + le(type) + le(1) + [11, 0]
    return head + [UInt8](repeating: digest, count: 32) + le(UInt32(label.utf8.count)) + label.utf8
  }
  func accepted(_ records: [UInt8], _ live: [UInt8: [UInt8]]? = nil) -> Bool {
    (header + records).withUnsafeBytes {
      confirmedColdPCR10($0, archive: .init(repeating: 1), configuration: .init(repeating: 2)) {
        pcr, replay in
        guard let live else { return true }
        return live[pcr] == (0..<32).map { replay[$0] }
      } != nil
    }
  }
  let archive = event(8, "Tarwin boot set", 1)
  let config = event(9, "Tarwin boot configuration", 2)
  let unrelated = event(5, "firmware", 1)
  #expect(accepted(unrelated + archive + unrelated + config + unrelated))
  let zero = [UInt8](repeating: 0, count: 32)
  func extend(_ before: [UInt8], _ byte: UInt8) -> [UInt8] {
    Array(SHA256.hash(data: before + Array(repeating: byte, count: 32)))
  }
  let older = event(8, "firmware", 4)
  let note = event(9, "not extended", 5, type: 3)
  let later = event(9, "firmware", 6)
  let live: [UInt8: [UInt8]] = [8: extend(extend(zero, 4), 1), 9: extend(extend(zero, 2), 6), 10: zero]
  let complete = older + archive + config + note + later
  func transfer(_ records: [UInt8], _ copy: UInt8 = 1, _ configuration: UInt8 = 2) -> Bool {
    (header + records).withUnsafeBytes {
      guard let pair = replayColdFirmwarePCRs($0, archive: .init(repeating: copy),
        configuration: .init(repeating: configuration), dedicatedBanks: true) else { return false }
      return (0..<32).map { pair.archive[$0] } == extend(zero, 1)
        && (0..<32).map { pair.configuration[$0] } == extend(zero, 2)
    }
  }
  #expect(transfer(unrelated + archive + note + config))
  #expect(!transfer(archive + config, 7))
  #expect(!transfer(archive + config, 1, 7))
  #expect(!transfer(event(8, "Tarwin boot set", 7) + config, 7))
  #expect(!transfer(complete))
  #expect(accepted(complete, live))
  #expect(!accepted(archive + config + later, live))
  #expect(!accepted(older + archive + config, live))
  for index: UInt8 in [8, 9, 10] {
    var wrong = live
    wrong[index]![31] ^= 1
    #expect(!accepted(complete, wrong))
  }
  for invalid in [[], archive, config, config + archive, archive + archive + config,
    archive + config + config, archive + config + event(10, "other", 0),
    archive + event(9, "Tarwin boot configuration", 1), event(8, "Tarwin boot set", 2) + config,
    event(9, "Tarwin boot set", 1) + config, event(8, "Tarwin boot set", 1, type: 3) + config,
    archive + config.dropLast()] {
    #expect(!accepted(invalid))
  }
}
