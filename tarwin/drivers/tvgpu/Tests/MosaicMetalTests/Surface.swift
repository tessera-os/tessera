import Metal
import MosaicMetal
import TvGpuGuest
import XCTest

final class SurfaceTests: XCTestCase {
  let grant = MosaicGrant(
    client: 5, compositor: 9, epoch: 7, surface: 19,
    width: 64, height: 48, chargedBytes: 12288)!
  let clearHex =
    "544d533101000100070000000000000001000000000000001300000000000000000000000000000015cd5b0700000000204080ff400000003000000000000000"
  let blitHex =
    "544d533101000200070000000000000002000000000000001300000000000000490000000000000015cd5b070000000000000000400000003000000000000000"
  func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

  func testGoldenVectorsRunOnMetalAndCannotRecycleBeforeCompositorRelease() throws {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device required") }
    let q = try XCTUnwrap(gpu.makeCommandQueue())
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: 64,
      height: 48, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    let target = try XCTUnwrap(gpu.makeTexture(descriptor: desc))
    let source = try XCTUnwrap(gpu.makeTexture(descriptor: desc))
    let copy = (0..<12288).map { UInt8(truncatingIfNeeded: $0 &* 37) }
    let region = MTLRegionMake2D(0, 0, 64, 48)
    copy.withUnsafeBytes {
      source.replace(
        region: region, mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: 256)
    }
    let driver = try XCTUnwrap(MetalSurfaceDevice(grant: grant, queue: q, target: target))
    var lane = MetalPresentationLane(grant)
    for (op, vector) in [(MetalSurfaceOp.clear(0xff80_4020), clearHex), (.blit(73), blitHex)] {
      let c = try XCTUnwrap(
        lane.present(
          by: 5, epoch: 7, now: 3, deadline: 123_456_789,
          operation: op, canRead: { $0 == 73 }
        ) { b in
          XCTAssertEqual(hex(b), vector)
          return driver.submit(bytes: b, by: 5) { $0 == 73 ? source : nil }
        })
      XCTAssertFalse(lane.reusable)
      XCTAssertFalse(lane.complete(MosaicReceipt(.released, command: c).bytes))
      XCTAssertNil(driver.release(by: 9, epoch: 7, serial: c.serial))
      let limit = ContinuousClock.now + .seconds(5)
      var reply: MosaicReceipt?
      repeat {
        reply = driver.poll()
        if reply == nil { Thread.sleep(forTimeInterval: 0.001) }
      } while reply == nil && ContinuousClock.now < limit
      let done = try XCTUnwrap(reply)
      XCTAssertEqual(done.phase, .rendered)
      XCTAssertTrue(lane.complete(done.bytes))
      XCTAssertFalse(lane.complete(done.bytes))
      XCTAssertNil(driver.release(by: 5, epoch: 7, serial: c.serial))
      XCTAssertFalse(lane.reusable)
      var pixels = [UInt8](repeating: 0, count: copy.count)
      pixels.withUnsafeMutableBytes {
        target.getBytes(
          $0.baseAddress!, bytesPerRow: 256,
          from: region, mipmapLevel: 0)
      }
      if case .clear = op {
        XCTAssertEqual(
          pixels, Array(repeating: [0x20, 0x40, 0x80, 0xff] as [UInt8], count: 3072).flatMap { $0 })
      } else {
        XCTAssertEqual(pixels, copy)
      }
      let released = try XCTUnwrap(driver.release(by: 9, epoch: 7, serial: c.serial))
      XCTAssertTrue(lane.complete(released.bytes))
      XCTAssertTrue(lane.reusable)
      XCTAssertEqual(driver.submit(bytes: c.bytes, by: 5) { _ in source }, .notSubmitted)
    }
  }

  func testWrongClientStaleEpochAndMissingReadGrantCannotSubmit() {
    var lane = MetalPresentationLane(grant)
    for (client, epoch, now, read): (UInt64, UInt64, UInt64, Bool) in [
      (6, 7, 0, true), (5, 8, 0, true), (5, 7, 8, true), (5, 7, 0, false),
    ] {
      XCTAssertNil(
        lane.present(
          by: client, epoch: epoch, now: now, deadline: 8, operation: .blit(1),
          canRead: { _ in read },
          submit: { _ in
            XCTFail()
            return .accepted
          }))
    }
    XCTAssertTrue(lane.reusable)
    XCTAssertNil(
      MosaicGrant(
        client: 5, compositor: 9, epoch: 7, surface: 19, width: 64, height: 48,
        chargedBytes: 12287))
    XCTAssertNil(
      lane.present(
        by: 5, epoch: 7, now: 1, deadline: 8, operation: .clear(0), canRead: { _ in false },
        submit: { _ in .indeterminate }))
    XCTAssertFalse(lane.reusable)
  }

  func testMalformedCommandsAndStaleReceipts() throws {
    var lane = MetalPresentationLane(grant)
    let c = try XCTUnwrap(
      lane.present(
        by: 5, epoch: 7, now: 1, deadline: 8, operation: .clear(255),
        canRead: { _ in false }, submit: { _ in .accepted }))
    for offset in [0, 4, 6, 8, 24, 32, 52, 56, 60] {
      var b = c.bytes
      b[offset] ^= 8
      XCTAssertNil(MetalSurfaceCommand(bytes: b, grant: grant))
    }
    XCTAssertNil(MetalSurfaceCommand(bytes: Array(c.bytes.dropLast()), grant: grant))
    let r = MosaicReceipt(.rendered, command: c)
    for offset in [0, 4, 6, 8, 16, 24] {
      var b = r.bytes
      b[offset] ^= 8
      XCTAssertFalse(lane.complete(b))
    }
    XCTAssertTrue(lane.complete(MosaicReceipt(.failed, command: c).bytes))
    XCTAssertFalse(lane.complete(r.bytes))
    XCTAssertFalse(lane.reusable)
  }
}
