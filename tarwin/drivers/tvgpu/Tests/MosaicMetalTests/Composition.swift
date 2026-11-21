import Metal
import MosaicMetal
import TvGpuGuest
import XCTest

final class CompositionTests: XCTestCase {
  func testRenderedLayersClippedBackToFrontAndInputUsesLatchedGeometry() throws {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device required") }
    let q = try XCTUnwrap(gpu.makeCommandQueue())
    func texture(_ w: Int, _ h: Int) throws -> any MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
      d.storageMode = .shared
      d.usage = [.renderTarget, .shaderRead]
      return try XCTUnwrap(gpu.makeTexture(descriptor: d))
    }
    func render(_ id: UInt64, _ color: UInt32, _ x: Int32, _ y: Int32) throws -> MosaicLayer {
      let g = try XCTUnwrap(
        MosaicGrant(
          client: id + 10, compositor: 99, epoch: 3, surface: id,
          width: 64, height: 48, chargedBytes: 12288))
      let d = try XCTUnwrap(MetalSurfaceDevice(grant: g, queue: q, target: try texture(64, 48)))
      var lane = MetalPresentationLane(g)
      let c = try XCTUnwrap(
        lane.present(
          by: g.client, epoch: 3, now: 1, deadline: 100, operation: .clear(color),
          canRead: { _ in false }
        ) { d.submit(bytes: $0, by: g.client) { _ in nil } })
      let limit = ContinuousClock.now + .seconds(5)
      var r: MosaicReceipt?
      repeat {
        r = d.poll()
        if r == nil { Thread.sleep(forTimeInterval: 0.001) }
      } while r == nil && ContinuousClock.now < limit
      XCTAssertEqual(r?.phase, .rendered)
      return MosaicLayer(device: d, frame: c, x: x, y: y)
    }
    let a = try render(1, 0xff00_77cc, -16, 8)
    let b = try render(2, 0xffff_aa00, 40, 24)
    let target = try texture(96, 64)
    XCTAssertNil(MosaicComposition.begin(by: 1, backbuffer: target, queue: q, layers: [a]))
    XCTAssertNil(MosaicComposition.begin(by: 99, backbuffer: target, queue: q, layers: [a, a]))
    let scene = try XCTUnwrap(
      MosaicComposition.begin(by: 99, backbuffer: target, queue: q, layers: [a, b]))
    XCTAssertNil(a.device.release(by: 99, epoch: 3, serial: 1))
    XCTAssertNil(MosaicComposition.begin(by: 99, backbuffer: target, queue: q, layers: [a]))
    XCTAssertFalse(scene.latch(by: 99))
    XCTAssertNil(scene.hit(x: 44, y: 30))
    let limit = ContinuousClock.now + .seconds(5)
    var receipts: [MosaicReceipt]?
    repeat {
      receipts = scene.collect()
      if receipts == nil { Thread.sleep(forTimeInterval: 0.001) }
    } while receipts == nil && ContinuousClock.now < limit
    XCTAssertEqual(receipts?.map(\.phase), [.released, .released])
    XCTAssertNil(scene.collect())
    XCTAssertNil(scene.hit(x: 44, y: 30))
    XCTAssertFalse(scene.latch(by: 1))
    XCTAssertTrue(scene.latch(by: 99))
    let front = try XCTUnwrap(scene.hit(x: 44, y: 30))
    XCTAssertEqual(front.client, 12)
    XCTAssertEqual(front.surface, 2)
    XCTAssertEqual(front.x, 4)
    XCTAssertEqual(front.y, 6)
    let back = try XCTUnwrap(scene.hit(x: 0, y: 8))
    XCTAssertEqual(back.surface, 1)
    XCTAssertEqual(back.x, 16)
    XCTAssertNil(scene.hit(x: 90, y: 5))
    XCTAssertNil(scene.hit(x: 96, y: 63))
    var pixels = [UInt32](repeating: 0, count: 96 * 64)
    pixels.withUnsafeMutableBytes {
      target.getBytes(
        $0.baseAddress!, bytesPerRow: 384,
        from: MTLRegionMake2D(0, 0, 96, 64), mipmapLevel: 0)
    }
    var expected = [UInt32](repeating: 0xff00_0000, count: 96 * 64)
    for y in 8..<56 { for x in 0..<48 { expected[y * 96 + x] = 0xff00_77cc } }
    for y in 24..<64 { for x in 40..<96 { expected[y * 96 + x] = 0xffff_aa00 } }
    XCTAssertEqual(expected, pixels)
    if let path = ProcessInfo.processInfo.environment["TARWIN_MOSAIC_CAPTURE"] {
      var ppm = Data("P6\n96 64\n255\n".utf8)
      for p in pixels {
        for shift in [16, 8, 0] { ppm.append(UInt8(truncatingIfNeeded: p >> shift)) }
      }
      try ppm.write(to: URL(fileURLWithPath: path))
    }
    scene.retire()
    XCTAssertNil(scene.hit(x: 44, y: 30))
  }
}
