import TarwinBoot
import TarwinKernelRandom
import TarwinRandomCore
import XCTest

final class FixedDebugLaunchTests: XCTestCase {
  private let fixed = RandomEpoch.fixedDebugQEMU(low: 9, high: 4)

  private func fixture() -> (block: [UInt8], map: [UInt8]) {
    var info = emptyBootInfo()
    info.security = 2
    info.year = 26; info.month = 11; info.week = 1
    info.bootSet = 0x8000; info.bootSetSize = 0x1000
    info.rsdp = 0x1000; info.mapAddress = 0x4000; info.mapCount = 2
    var block = (0..<4096).map { bootInfoByte(info, offset: UInt64($0)) }
    let id = DebugQEMUFixedGeneration(low: 9, high: 4)!
    XCTAssertTrue(block.withUnsafeMutableBytes { id.encode(in: $0) })
    let regions = [PhysicalRegion(base: 0x3000, length: 0x2000, kind: 8, attributes: 8),
      PhysicalRegion(base: 0x8000, length: 0x1000, kind: 7, attributes: 8)]
    return (block, regions.flatMap { r in (0..<32).map { regionByte(r, offset: UInt64($0)) } })
  }

  private func open(_ block: [UInt8], _ map: [UInt8], _ policy: KernelEntropyPolicy = .debugQEMU,
    migrate: Bool = false, snapshots: Bool = false, sample: [UInt8] = Array(0..<32),
    source: CheckedEntropySource = .emulatedTPM) -> FixedDebugRandomLaunch? {
    var launch: FixedDebugRandomLaunch?
    block.withUnsafeBytes { b in map.withUnsafeBytes { m in sample.withUnsafeBytes { h in
      launch = FixedDebugRandomLaunch(policy: policy, allowsMigration: migrate, allowsSnapshots: snapshots,
        block: b, at: 0x3000, map: m, at: 0x4000, hardware: h, source: source)
    } } }
    return consume launch
  }

  func testAdmissionRequiresIndependentPolicyAndEveryInput() {
    let (b, m) = fixture()
    XCTAssertTrue(open(b, m, .certified, source: .physicalHardware) == nil)
    XCTAssertTrue(open(b, m, migrate: true) == nil)
    XCTAssertTrue(open(b, m, snapshots: true) == nil)
    XCTAssertTrue(open(b, m, sample: []) == nil)
    XCTAssertTrue(open(b, m, source: .uncredited) == nil)
    XCTAssertTrue(open(b, Array(m.dropLast())) == nil)
    for i in [7, 177, 216, 240] {
      var bad = b; bad[i] ^= 1
      XCTAssertTrue(open(bad, m) == nil)
    }
    var zero = b
    zero.replaceSubrange(224..<240, with: repeatElement(0, count: 16))
    XCTAssertTrue(open(zero, m) == nil)
    b.withUnsafeBytes { raw in
      let seed = UnsafeRawBufferPointer(rebasing: raw[96..<160])
      let hw = UnsafeRawBufferPointer(rebasing: raw[..<32])
      for policy in [KernelEntropyPolicy.debugQEMU, .certified] {
        XCTAssertTrue(KernelRandom(policy: policy, bootSeed: seed, hardware: hw,
          source: .physicalHardware, generation: fixed) == nil)
      }
      let live = RandomEpoch.virtualMachine(low: 9, high: 4)
      var rng = KernelRandom(policy: .debugQEMU, bootSeed: seed, hardware: hw,
        source: .physicalHardware, generation: live)!
      XCTAssertFalse(rng.reseed(hardware: hw, source: .physicalHardware, generation: fixed))
      XCTAssertNil(rng.word(generation: fixed))
    }
  }

  func testIdenticalWordsFromLiveAndFixedSourcesAreNotInterchangeable() {
    let (b, m) = fixture()
    let live = RandomEpoch.virtualMachine(low: 9, high: 4)
    b.withUnsafeBytes { raw in Array(UInt8(0)..<32).withUnsafeBytes { sample in
      var device = KernelRandom(policy: .debugQEMU, bootSeed: .init(rebasing: raw[96..<160]),
        hardware: sample, source: .emulatedTPM, generation: live)!
      var launch = open(b, m)!
      XCTAssertEqual(launch.generation, fixed)
      let word = launch.random.word(generation: fixed)
      XCTAssertNotNil(word)
      XCTAssertNotEqual(word, device.word(generation: live))
      XCTAssertTrue(launch.random.reseed(hardware: sample, source: .emulatedTPM, generation: fixed))
      for wrong in [nil, .physical, live, RandomEpoch.fixedDebugQEMU(low: 8, high: 4)] {
        var denied = open(b, m)!
        XCTAssertNil(denied.random.word(generation: wrong))
        XCTAssertFalse(denied.random.reseed(hardware: sample, source: .emulatedTPM, generation: fixed))
        XCTAssertNil(denied.random.word(generation: fixed))
        var rotated = open(b, m)!
        XCTAssertFalse(rotated.random.reseed(hardware: sample, source: .emulatedTPM, generation: wrong))
        XCTAssertNil(rotated.random.word(generation: fixed))
      }
    } }
  }
}
