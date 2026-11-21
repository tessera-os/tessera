import XCTest

@testable import VirtioGuest

final class MmioTests: XCTestCase {
  func testDeviceRejectingFeaturesNeverGetsDriverOk() {
    var status: UInt32 = 0
    var high: UInt32 = 0
    let read: (UInt32) -> UInt32 = { reg in
      if reg == 0 { return 0x7472_6976 }
      if reg == 4 || reg == 8 { return 2 }
      if reg == 0x70 { return status }
      if reg == 0x10 && high == 1 { return 3 }
      return 0
    }
    let write: (UInt32, UInt32) -> Void = { reg, v in
      if reg == 0x70 { status = v == 11 ? 3 : v }
      if reg == 0x14 { high = v }
    }
    XCTAssertTrue(negotiateMmio(2, 0, read, write, { return false }) == MmioFeatures.unavailable)
    XCTAssertTrue(!driverReady(read, write))
    XCTAssertTrue(status == 0x83)
  }

  func testReadRequestPublishesHeaderThenDeviceWritableDataAndStatus() {
    var q = SplitQueue()
    XCTAssertTrue(q.initialize(4))
    var packedFlags: UInt16 = 0
    var header: UInt64 = 0
    var pending: UInt8 = 0
    let packet = BlockPacket(
      op: .read, sector: 3, bytes: 512, header: 4096, data: 8192, status: 12288)
    XCTAssertTrue(
      submitBlock(
        &q, 1, packet, 4, 0, { a, k, s in header = s },
        { a, v in pending = v }, { i, a, n, f, l in packedFlags = (packedFlags << 4) | f },
        { i, h in }, { idx in }))
    XCTAssertTrue(blockCompletion(0, .read, 512, 1) == GuestBlockResult.protocolError)
    XCTAssertTrue(blockCompletion(0, .read, 512, 513) == GuestBlockResult.ok)
    XCTAssertTrue(header == 3 && pending == 255 && packedFlags == 0x132)
    XCTAssertTrue(blockCompletion(pending, .read, 512, 513) == GuestBlockResult.protocolError)
  }
}
