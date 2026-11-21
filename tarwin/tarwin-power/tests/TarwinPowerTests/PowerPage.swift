import Synchronization
import TarwinPower
import XCTest

final class PowerPageTests: XCTestCase {
  func sample(_ time: UInt64) -> PowerSample {
    PowerSample(
      percent: 72, state: 2, external: 1, thermal: .serious, lowPower: true, timeToEmpty: 0,
      timeToFull: 1_234_567, drawMilliwatts: 3456, cpuThrottle: 25, gpuThrottle: 7, updated: time)!
  }
  func testPublicationMatchesLibTesseraOffsetsAndPublishesBeforeSignal() throws {
    let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { page.deallocate() }
    var writer = PowerPageWriter(initializing: page)!
    XCTAssertNil(readPowerPage(UnsafeRawBufferPointer(page)))
    let value = sample(101)
    var notifications = 0
    XCTAssertTrue(
      writer.publish(value) {
        notifications += 1
        XCTAssertEqual(readPowerPage(UnsafeRawBufferPointer(page)), value)
      })
    // Decode independent little-endian fields as a read-only client would.
    func word(_ at: Int, _ width: Int) -> UInt64 {
      (0..<width).reduce(0) { $0 | UInt64(page[at + $1]) << ($1 * 8) }
    }
    XCTAssertEqual(
      [
        word(0, 4), word(4, 4), word(8, 4), word(12, 4), word(16, 8), word(24, 8), word(32, 8),
        word(40, 4), word(44, 4), word(48, 4), word(52, 4), word(56, 8), word(64, 8),
      ],
      [72, 2, 1, 2, 1, 0, 1_234_567, 3456, 25, 7, 0, 101, 2])
    XCTAssertTrue(page[72...].allSatisfy { $0 == 0 })
    XCTAssertFalse(writer.publish(sample(100)) { notifications += 1 })
    XCTAssertEqual(notifications, 1)
    XCTAssertEqual(readPowerPage(UnsafeRawBufferPointer(page)), value)
  }
  func testInterruptedWriterAndCorruptRecordsAreNeverReturned() {
    let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
    defer { page.deallocate() }
    var writer = PowerPageWriter(initializing: page)!
    XCTAssertTrue(writer.publish(sample(42)) {})
    let w = page.baseAddress!.assumingMemoryBound(to: Atomic<UInt64>.self)
    w[8].store(3, ordering: .sequentiallyConsistent)
    XCTAssertNil(readPowerPage(UnsafeRawBufferPointer(page)))
    w[2].store(256, ordering: .sequentiallyConsistent)
    w[8].store(4, ordering: .sequentiallyConsistent)
    XCTAssertNil(readPowerPage(UnsafeRawBufferPointer(page)))
    w[8].store(UInt64.max - 1, ordering: .sequentiallyConsistent)
    XCTAssertFalse(writer.publish(sample(43)) { XCTFail() })
    XCTAssertNil(readPowerPage(UnsafeRawBufferPointer(rebasing: page[1...])))
  }
}
