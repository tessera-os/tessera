import Synchronization
import TarwinIPC
import XCTest

@testable import TarwinDevice

final class IoRingTests: XCTestCase {
  func testBackpressureIdleNotificationAndMaskedSlotsInBothDirections() {
    let region = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096 + 8192, alignment: 4096)
    defer { region.deallocate() }
    XCTAssertTrue(IoRingMapping.initialize(region, count: 64, stride: 64))
    let pair = IoRingMapping(attaching: region)!
    for completion in [false, true] {
      var tx = pair.lane(completion: completion, producer: true)
      var rx = pair.lane(completion: completion, producer: false)
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { row in
        row.initialize(repeating: 0)
        defer { row.deinitialize() }
        var signals = 0
        for iteration in 0..<2 {
          XCTAssertEqual(rx.arm(), .wait)
          for i in 0..<64 {
            row[0] = UInt8(64 * iteration + i)
            XCTAssertEqual(tx.transfer(row) { signals += 1 }, .transferred)
          }
          XCTAssertEqual(tx.transfer(row) { XCTFail() }, .wait)
          XCTAssertEqual(tx.arm(), .wait)
          for i in 0..<64 {
            XCTAssertEqual(rx.transfer(row) { signals += 1 }, .transferred)
            XCTAssertEqual(row[0], UInt8(64 * iteration + i))
          }
          XCTAssertEqual(rx.transfer(row) { XCTFail() }, .wait)
        }
        XCTAssertTrue(signals >= 4)
      }
    }
  }
  func testHostilePeerCannotChangeGeometryOrForgeCompletions() {
    let region = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096 + 8192, alignment: 4096)
    defer { region.deallocate() }
    XCTAssertFalse(IoRingMapping.initialize(region, count: 64, stride: 128))
    XCTAssertTrue(IoRingMapping.initialize(region, count: 64, stride: 64))
    var rx = IoRingMapping(attaching: region)!.lane(completion: true, producer: false)
    func write(_ offset: Int, _ value: UInt32) {
      region.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Atomic<UInt32>.self)
        .pointee.store(value.littleEndian, ordering: .releasing)
    }
    write(12, .max)
    XCTAssertNil(IoRingMapping(attaching: region))
    write(Int(RingFormat.completionProducer), 65)
    XCTAssertEqual(rx.arm(), .invalid)
    write(Int(RingFormat.completionProducer), 0)
    XCTAssertEqual(rx.arm(), .invalid)
  }
}
