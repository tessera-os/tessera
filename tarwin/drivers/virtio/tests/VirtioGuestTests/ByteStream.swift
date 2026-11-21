import VirtioGuest
import XCTest

final class ByteStreamTests: XCTestCase {
  func testShortInputHeldUntilRetiredAndTailNeverDelivered() {
    for channel in [ByteChannel.entropy, .consoleReceive, .consoleTransmit] {
      var stream = ByteStreamQueue(channel: channel, count: 8)!
      var head: UInt16 = 0
      var idx: UInt16 = 0
      let descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void = { _, addr, len, flags, next in
        XCTAssertEqual(addr, 0x4000)
        XCTAssertEqual(len, 63)
        XCTAssertEqual(flags, channel.deviceWrites ? 2 : 0)
        XCTAssertEqual(next, 0)
      }
      func post(_ addr: UInt64, _ n: UInt32) -> Bool {
        stream.submit(
          iova: addr, length: n, descriptor: descriptor, available: { _, id in head = id },
          publish: { idx = $0 })
      }
      XCTAssertFalse(post(.max, 2))
      XCTAssertFalse(post(0, 65537))
      XCTAssertEqual(idx, 0)
      XCTAssertTrue(post(0x4000, 63))
      XCTAssertFalse(post(0x4000, 63))
      XCTAssertNil(
        stream.release {
          XCTFail()
          return true
        })
      stream.poll(
        acquire: { idx }, head: { _ in UInt32(head) },
        written: { _ in channel.deviceWrites ? 3 : 0 })
      XCTAssertNil(stream.release { false })
      XCTAssertFalse(post(0x4000, 63))
      stream.poll(
        acquire: {
          XCTFail()
          return 1
        }, head: { _ in 0 }, written: { _ in 63 })
      let expected: ByteDelivery =
        channel == .entropy
        ? .uncreditedRandom(3) : channel == .consoleReceive ? .consoleInput(3) : .consoleSent(63)
      XCTAssertEqual(stream.release { true }, expected)
      XCTAssertNil(
        stream.release {
          XCTFail()
          return false
        })
      XCTAssertTrue(post(0x4000, 63))
      stream.stop()
      XCTAssertNil(stream.release { false })
      XCTAssertEqual(stream.release { true }, .dropped)
      XCTAssertFalse(post(0x4000, 63))
    }
  }
  func testEmptyAndOversizedEntropyCannotReachConsumer() {
    for length: UInt32 in [0, 9] {
      var s = ByteStreamQueue(channel: .entropy, count: 2)!
      XCTAssertTrue(
        s.submit(
          iova: 64, length: 8, descriptor: { _, _, _, _, _ in }, available: { _, _ in },
          publish: { _ in }))
      s.poll(acquire: { 1 }, head: { _ in 0 }, written: { _ in length })
      XCTAssertEqual(s.release { true }, .dropped)
      XCTAssertFalse(
        s.submit(
          iova: 64, length: 8, descriptor: { _, _, _, _, _ in }, available: { _, _ in },
          publish: { _ in }))
    }
  }
}
