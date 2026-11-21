import Foundation
import TarwinKernelRandom
import TarwinLoader
import XCTest

@testable import TarwinRandomCore

private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

final class RandomTests: XCTestCase {
  func testReseedLimitAndRejectedPlatformChange() {
    [UInt8](0..<64).withUnsafeBytes { boot in
      let sample = UnsafeRawBufferPointer(rebasing: boot[..<32])
      guard
        var rng = KernelRandom(
          policy: .certified, bootSeed: boot, hardware: sample,
          source: .physicalHardware, generation: .physical)
      else { return XCTFail() }
      XCTAssertNotNil(rng.word(generation: .physical))
      XCTAssertEqual(rng.remainingBlocks, KernelRandom.blocksPerSample - 1)
      var data = [UInt8](repeating: 0, count: rng.remainingBlocks * 32)
      data.withUnsafeMutableBytes { XCTAssertTrue(rng.fill($0, generation: .physical)) }
      XCTAssertNil(rng.word(generation: .physical))
      XCTAssertTrue(rng.reseed(hardware: sample, source: .physicalHardware, generation: .physical))
      XCTAssertNotNil(rng.word(generation: .physical))
      XCTAssertFalse(
        rng.reseed(
          hardware: sample, source: .physicalHardware, generation: .virtualMachine(low: 1, high: 1))
      )
      XCTAssertNil(rng.word(generation: .physical))
    }
  }
  func testOfficialBlake3DerivationVectors() {
    let context: StaticString = "BLAKE3 2019-12-27 16:29:52 test vectors context"
    for (n, expected) in [
      (0, "2cc39783c223154fea8dfb7c1b1660f2ac2dcbd1c1de8277b0b0dd39b7e50d7d"),
      (63, "b6451e30b953c206e34644c6803724e9d2725e0893039cfc49584f991f451af3"),
      (64, "a5c4a7053fa86b64746d4bb688d06ad1f02a18fce9afd3e818fefaa7126bf73e"),
      (65, "51fd05c3c1cfbc8ed67d139ad76f5cf8236cd2acd26627a30c104dfd9d3ff8a8"),
      (1024, "7356cd7720d5b66b6d0697eb3177d9f8d73a4a5c5e968896eb6a689684302706"),
    ] {
      (0..<n).map { UInt8($0 % 251) }.withUnsafeBytes { b in
        guard let c = deriveSmallBlakeKey(context: context, material: b) else { return XCTFail() }
        XCTAssertEqual(
          hex(
            [c.w0, c.w1, c.w2, c.w3, c.w4, c.w5, c.w6, c.w7].flatMap { w in
              (0..<4).map { UInt8(truncatingIfNeeded: w >> (8 * $0)) }
            }), expected)
      }
    }
    [UInt8](repeating: 0, count: 1025).withUnsafeBytes {
      XCTAssertNil(deriveSmallBlakeKey(context: context, material: $0))
    }
  }
  func testRFC8439BlockAndOpenSSLRekeyStream() {
    var key = InlineArray<8, UInt32>(repeating: 0)
    for i in 0..<32 { key[i / 4] |= UInt32(i) << (8 * (i % 4)) }
    let block = chachaBlock(key, 1, 0x0900_0000, 0x4a00_0000, 0)
    let output = (0..<64).map { UInt8(truncatingIfNeeded: block[$0 / 4] >> (8 * ($0 % 4))) }
    XCTAssertEqual(
      hex(output),
      "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e"
        + "d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e")
    var s = ChaChaStream(keyWords: .init(repeating: 0))
    var bytes = [UInt8](repeating: 0, count: 63)
    bytes.withUnsafeMutableBytes { s.fill($0) }
    XCTAssertEqual(
      hex(bytes),
      "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586"
        + "afbdad2845b93cdbb2fe6463d2fe162adae0f6e676f0494218f5ce0596e79f")
  }
  func testCredentialAndGenerationChecks() {
    let before = RandomEpoch.virtualMachine(low: 1, high: 2)
    let after = RandomEpoch.virtualMachine(low: 3, high: 4)
    var output = [UInt8](repeating: 0xa5, count: 35)
    [UInt8](0..<64).withUnsafeBytes { boot in
      [UInt8](64..<96).withUnsafeBytes { hw in
        func canSeed(
          _ policy: KernelEntropyPolicy, _ source: CheckedEntropySource, _ at: RandomEpoch?
        ) -> Bool {
          if KernelRandom(
            policy: policy, bootSeed: boot, hardware: hw, source: source, generation: at) != nil
          {
            return true
          }
          return false
        }
        XCTAssertFalse(canSeed(.certified, .emulatedTPM, before))
        XCTAssertFalse(canSeed(.debugQEMU, .uncredited, before))
        XCTAssertFalse(canSeed(.debugQEMU, .emulatedTPM, nil))
        XCTAssertFalse(canSeed(.debugQEMU, .emulatedTPM, .physical))
        XCTAssertFalse(canSeed(.debugQEMU, .emulatedTPM, .virtualMachine(low: 0, high: 0)))
        XCTAssertTrue(canSeed(.certified, .physicalHardware, .physical))
        guard
          var rng = KernelRandom(
            policy: .debugQEMU, bootSeed: boot, hardware: hw, source: .emulatedTPM,
            generation: before)
        else { return XCTFail("boot and post-boot inputs") }
        let first = rng.word(generation: before)
        XCTAssertNotNil(first)
        XCTAssertNotEqual(rng.word(generation: before), first)
        output.withUnsafeMutableBytes { XCTAssertFalse(rng.fill($0, generation: after)) }
        XCTAssertEqual(output, [UInt8](repeating: 0xa5, count: 35))
        XCTAssertNil(rng.word(generation: before))
        XCTAssertFalse(rng.reseed(hardware: boot, source: .emulatedTPM, generation: after))
        XCTAssertFalse(rng.reseed(hardware: hw, source: .uncredited, generation: after))
        XCTAssertNil(rng.word(generation: after))
        XCTAssertTrue(rng.reseed(hardware: hw, source: .emulatedTPM, generation: after))
        XCTAssertNotNil(rng.word(generation: after))
        XCTAssertNil(rng.word(generation: nil))
        XCTAssertNil(rng.word(generation: after))
      }
    }
  }
  func testThreadDiscardsStreamUntilFreshKernelSeed() {
    let a = RandomEpoch.virtualMachine(low: 7, high: 1)
    let b = RandomEpoch.virtualMachine(low: 7, high: 2)
    var t = ThreadRandomState()
    var out = [UInt8](repeating: 42, count: 48)
    out.withUnsafeMutableBytes { dst in
      XCTAssertFalse(t.fill(dst, current: a))
      [UInt8](0..<32).withUnsafeBytes { seed in
        XCTAssertTrue(t.replace(seed: seed, at: a))
        XCTAssertTrue(t.fill(dst, current: a))
        let previous = Array(dst)
        XCTAssertFalse(t.fill(dst, current: b))
        XCTAssertFalse(t.fill(dst, current: a))
        XCTAssertEqual(Array(dst), previous)
        XCTAssertFalse(t.replace(seed: seed, at: nil))
        XCTAssertFalse(t.replace(seed: .init(rebasing: seed[..<31]), at: b))
        XCTAssertTrue(t.replace(seed: seed, at: b))
        XCTAssertTrue(t.fill(dst, current: b))
      }
    }
  }
}
