import TRFS
import XCTest

private struct FaultableCipher: XtsCipher {
  let keyObject: UInt64
  var left: Int
  mutating func encryptTweak(_ b: CipherBlock) -> CipherBlock? { b }
  mutating func data(_ b: CipherBlock, decrypt: Bool) -> CipherBlock? {
    guard left > 0 else { return nil }
    left -= 1
    return b
  }
}
final class XtsSectorTests: XCTestCase {
  func testRejectsOverlappingMappingsAndOverlappingPhysicalAliases() {
    let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 8)
    defer { memory.deallocate() }
    let cache = SectorPin(physical: 0x1000, bytes: .init(rebasing: memory[0..<512]))!
    let unit = EncryptedUnit(block: 2, tweak: 4, keyObject: 3)
    for p in [
      SectorPin(physical: 0x1100, bytes: .init(rebasing: memory[512...]))!,
      SectorPin(physical: 0x3000, bytes: .init(rebasing: memory[256..<768]))!,
    ] {
      if XtsSector(unit: unit, cache: cache, staging: p) != nil { XCTFail("alias accepted") }
    }
    XCTAssertNil(SectorPin(physical: .max - 15, bytes: memory))
    XCTAssertNil(SectorPin(physical: 0, bytes: .init(rebasing: memory[..<17])))
  }
  func testFailureCannotBeReplayedAfterDrainAndNeverPublishesPartialPlaintext() {
    let cache = UnsafeMutableRawBufferPointer.allocate(byteCount: 512, alignment: 8)
    let stage = UnsafeMutableRawBufferPointer.allocate(byteCount: 512, alignment: 8)
    defer {
      cache.deallocate()
      stage.deallocate()
    }
    let cp = SectorPin(physical: 0x1000, bytes: cache)!
    let sp = SectorPin(physical: 0x2000, bytes: stage)!
    let unit = EncryptedUnit(block: 7, tweak: 255, keyObject: 99)
    let erase: (UnsafeMutableRawBufferPointer) -> Void = { b in for i in b.indices { b[i] = 0 } }
    for fault in 0..<3 {
      cache.initializeMemory(as: UInt8.self, repeating: 0x88)
      stage.initializeMemory(as: UInt8.self, repeating: 0xab)
      var cipher = FaultableCipher(keyObject: 99, left: fault == 0 ? 31 : 32)
      var io = XtsSector(unit: unit, cache: cp, staging: sp)!
      XCTAssertTrue(
        io.begin(read: true, cipher: &cipher, erase: erase) { block, phys, n, w in
          XCTAssertEqual(block, 7)
          XCTAssertEqual(phys, 0x2000)
          XCTAssertEqual(n, 512)
          XCTAssertTrue(w)
          XCTAssertTrue(stage.allSatisfy { $0 == 0 })
          for i in stage.indices { stage[i] = 0xba }
          return true
        })
      XCTAssertEqual(
        io.finish(
          transferred: fault == 1 ? 511 : 512, cipher: &cipher, drain: { false }, erase: erase),
        .waiting)
      XCTAssertTrue(cache.allSatisfy { $0 == 0x88 })
      XCTAssertTrue(stage.allSatisfy { $0 == 0xba })
      if fault == 2 { cipher = FaultableCipher(keyObject: 7, left: 32) }
      XCTAssertEqual(
        io.finish(transferred: 512, cipher: &cipher, drain: { true }, erase: erase), .failed)
      XCTAssertTrue(cache.allSatisfy { $0 == 0 })
      XCTAssertTrue(stage.allSatisfy { $0 == 0 })
      XCTAssertEqual(
        io.finish(
          transferred: 512, cipher: &cipher,
          drain: {
            XCTFail()
            return true
          }, erase: erase), .inactive)
    }
    var io = XtsSector(unit: unit, cache: cp, staging: sp)!
    var wrong = FaultableCipher(keyObject: 99, left: 1)
    XCTAssertFalse(
      io.begin(read: false, cipher: &wrong, erase: erase) { _, _, _, _ in
        XCTFail()
        return true
      })
    XCTAssertTrue(stage.allSatisfy { $0 == 0 })
  }
}
