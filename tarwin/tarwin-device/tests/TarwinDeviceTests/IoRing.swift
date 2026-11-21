import Synchronization
import TarwinIPC
import XCTest

@testable import TarwinDevice

final class IoRingTests: XCTestCase {
  func testBackpressureIdleNotificationAndMaskedSlotsInBothDirections() {
    let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096 + 8192, alignment: 4096)
    defer { memory.deallocate() }
    let pair = IoRingMapping(initializing: memory, count: 64, stride: 64)!
    for completion in [false, true] {
      var tx = pair.endpoint(completion: completion, producer: true)!
      var rx = pair.endpoint(completion: completion, producer: false)!
      var row = RingRecord()
      for iteration in 0..<2 {
        XCTAssertEqual(rx.pop(into: &row), .wait)
        for i in 0..<64 {
          row.words[0] = UInt32(64 * iteration + i)
          XCTAssertEqual(tx.push(row), .transferred(notifyPeer: true))
        }
        XCTAssertEqual(tx.push(row), .wait)
        for i in 0..<64 {
          XCTAssertEqual(rx.pop(into: &row), .transferred(notifyPeer: true))
          XCTAssertEqual(row.words[0], UInt32(64 * iteration + i))
        }
      }
    }
  }
  func testHostilePeerCannotChangeGeometryOrForgeCompletions() {
    let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096 + 8192, alignment: 4096)
    defer { memory.deallocate() }
    XCTAssertNil(IoRingMapping(initializing: memory, count: 64, stride: 128))
    let pair = IoRingMapping(initializing: memory, count: 64, stride: 64)!
    var rx = pair.endpoint(completion: true, producer: false)!
    var row = RingRecord()
    func write(_ offset: Int, _ value: UInt32) {
      memory.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Atomic<UInt32>.self)
        .pointee.store(value, ordering: .releasing)
    }
    write(12, .max)
    XCTAssertTrue(pair.endpoint(completion: false, producer: true) == nil)
    write(Int(RingFormat.completionProducer), 65)
    XCTAssertEqual(rx.pop(into: &row), .invalidPeer)
    write(Int(RingFormat.completionProducer), 0)
    XCTAssertEqual(rx.pop(into: &row), .invalidPeer)
  }
}
