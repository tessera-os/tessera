import XCTest

@testable import NativeDriverKit

final class AccessTests: XCTestCase {
  func testNoncoherentOwnershipNeverChangesAfterFailedCacheMaintenance() {
    let b = NativeDmaBuffer(handle: 5, iova: 8192, length: 4096, direction: .fromDevice)
    let failSync: (UInt64, DmaDirection) -> Bool = { h, d in return false }
    let sync: (UInt64, DmaDirection) -> Bool = { h, d in return h == 5 && d == .fromDevice }
    let close: (UInt64) -> Bool = { h in return h == 5 }
    XCTAssertTrue(b.suitable(4096, 8192))
    XCTAssertTrue(!b.suitable(4096, 2048))
    XCTAssertTrue(!b.prepareForDevice(failSync))
    XCTAssertTrue(b.prepareForDevice(sync))
    XCTAssertTrue(!b.retire(close))
    XCTAssertTrue(!b.completeFromDevice(failSync))
    XCTAssertTrue(b.owner == BufferOwner.device)
    XCTAssertTrue(b.completeFromDevice(sync))
    XCTAssertTrue(b.retire(close))
    XCTAssertTrue(!b.prepareForDevice(sync))
  }

  func testAliasesShareOneGrantAndOneRetirement() {
    let buffer = NativeDmaBuffer(handle: 17, iova: 4096, length: 4096, direction: .toDevice)
    let alias = buffer
    var calls = 0
    XCTAssertTrue(
      buffer.prepareForDevice { _, _ in
        XCTAssertFalse(
          alias.retire { _ in
            XCTFail()
            return true
          })
        return true
      })
    XCTAssertEqual(alias.owner, .device)
    XCTAssertFalse(
      alias.retire { _ in
        XCTFail()
        return true
      })
    XCTAssertTrue(alias.completeFromDevice { _, _ in true })
    XCTAssertFalse(
      buffer.retire { _ in
        calls += 1
        return false
      })
    XCTAssertEqual(alias.owner, .retiring)
    XCTAssertFalse(
      alias.prepareForDevice { _, _ in
        XCTFail()
        return true
      })
    XCTAssertTrue(
      alias.retire { _ in
        XCTAssertFalse(
          buffer.retire { _ in
            XCTFail()
            return true
          })
        calls += 1
        return true
      })
    XCTAssertTrue(
      buffer.retire { _ in
        XCTFail()
        return true
      })
    XCTAssertEqual(calls, 2)
  }

  func testDriverApiRefusesExpiredFutureOrPreTarwinDrivers() {
    XCTAssertTrue(compatibleDriver(27, 10, 26, 11))
    XCTAssertTrue(!compatibleDriver(27, 11, 26, 11))
    XCTAssertTrue(!compatibleDriver(26, 11, 26, 10))
    XCTAssertTrue(!compatibleDriver(26, 11, 26, 12))
  }

  func testPreparedRangeSplitsAtHardwareBoundariesBeforePublication() {
    let b = NativeDmaBuffer(handle: 5, iova: 0x1fec, length: 8192, direction: .fromDevice)
    let limits = DmaSegmentLimits(granularity: 4, maximumBytes: 1027, boundary: 4096, count: 4)!
    func post(_ offset: UInt64, _ n: UInt64, _ access: DmaDirection, _ l: DmaSegmentLimits) -> Bool
    {
      b.withDeviceSegments(offset: offset, bytes: n, access: access, limits: l) { _ in
        XCTFail("Published invalid list")
        return true
      }
    }
    XCTAssertFalse(post(4, 2048, .fromDevice, limits))
    XCTAssertTrue(b.prepareForDevice { _, _ in true })
    XCTAssertFalse(post(4, 2048, .toDevice, limits))
    XCTAssertFalse(post(4, 2048, .bidirectional, limits))
    XCTAssertFalse(post(5, 2048, .fromDevice, limits))
    XCTAssertFalse(post(4, 2047, .fromDevice, limits))
    XCTAssertFalse(post(.max, 4, .fromDevice, limits))
    XCTAssertFalse(post(4, .max, .fromDevice, limits))
    XCTAssertFalse(
      post(
        4, 2048, .fromDevice,
        DmaSegmentLimits(granularity: 4, maximumBytes: 1024, boundary: 4096, count: 2)!))
    XCTAssertTrue(
      b.withDeviceSegments(offset: 4, bytes: 2048, access: .fromDevice, limits: limits) { spans in
        XCTAssertEqual(spans.map(\.iova), [0x1ff0, 0x2000, 0x2400])
        XCTAssertEqual(spans.map(\.bytes), [16, 1024, 1008])
        XCTAssertFalse(
          b.completeFromDevice { _, _ in
            XCTFail()
            return true
          })
        return true
      })
    XCTAssertTrue(b.completeFromDevice { _, _ in true })
    XCTAssertFalse(post(4, 2048, .fromDevice, limits))
  }
  func testTopOfAddressSpaceAndInvalidSegmentLimits() {
    let b = NativeDmaBuffer(handle: 7, iova: .max - 15, length: 16, direction: .bidirectional)
    XCTAssertTrue(b.prepareForDevice { _, _ in true })
    XCTAssertTrue(
      b.withDeviceSegments(
        offset: 8, bytes: 8, access: .toDevice,
        limits: DmaSegmentLimits(granularity: 4, maximumBytes: 8, count: 1)!
      ) { $0.count == 1 && $0[0].iova == .max - 7 })
    for (g, max, boundary, n) in [
      (0, 4, 4, 1), (3, 6, 0, 1), (8, 4, 8, 1), (4, 4, 2, 1), (4, 4, 6, 1), (4, 4, 0, 0),
      (4, 4, 0, 65537),
    ] {
      XCTAssertNil(
        DmaSegmentLimits(
          granularity: UInt64(g), maximumBytes: UInt64(max), boundary: UInt64(boundary), count: n))
    }
  }
}
