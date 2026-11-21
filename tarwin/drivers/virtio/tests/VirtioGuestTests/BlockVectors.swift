import TarwinBlockWire
import VirtioBlockService
import VirtioGuest
import XCTest

final class BlockVectorTests: XCTestCase {
  func config(segments: UInt32 = 2, size: UInt32 = 320, features: UInt64 = 6) -> BlockConfiguration?
  {
    var b = [UInt8](repeating: 0, count: 16)
    b[0] = 100
    for i in 0..<4 {
      b[8 + i] = UInt8(truncatingIfNeeded: size >> (8 * i))
      b[12 + i] = UInt8(truncatingIfNeeded: segments >> (8 * i))
    }
    return BlockConfiguration.snapshot(
      features: features, configBytes: 16, generation: { 0 }, read: { b[$0] })
  }
  func testLimitSnapshotBoundsAndRequiresCompleteNegotiatedFields() {
    XCTAssertNil(config(segments: 0))
    XCTAssertNil(config(size: 0))
    XCTAssertEqual(config(segments: .max)?.maxSegments, 128)
    XCTAssertEqual(config(features: 0)?.maxSegments, 1)
    XCTAssertEqual(config(features: 0)?.maxSegmentBytes, .max)
    for (f, len): (UInt64, UInt64) in [(2, 11), (4, 15), (6, 12)] {
      XCTAssertNil(
        BlockConfiguration.snapshot(
          features: f, configBytes: len, generation: { 0 },
          read: { _ in
            XCTFail()
            return 0
          }))
    }
  }

  private func prepare(
    _ cfg: BlockConfiguration, _ vectors: [BlockDmaVector], read: (UInt64) -> Void = { _ in },
    allow: (UInt64, UInt64, Bool) -> Bool = { _, _, _ in true }
  ) -> DriverRequest {
    let request = BlockRequest(
      id: 4, epoch: 7, lba: 2, blocks: 1, queue: 0, op: .read, qos: .interactive,
      payload: BlockPayload(list: 512, vectors: UInt32(vectors.count)))!
    return prepareBlockIo(
      request.record(), epoch: 7, queue: 0, config: cfg, header: 1024, status: 1280,
      rangeBuffer: nil, allows: allow,
      readVector: { at in
        read(at)
        return vectors[Int((at - 512) / 16)]
      })
  }
  func testInvalidVectorCannotPublishOrBorrowAnotherSpan() {
    let cfg = config()!
    let a = BlockDmaVector(address: 1536, bytes: 192)
    let b = BlockDmaVector(address: 4096, bytes: 320)
    for v in [
      BlockDmaVector(address: 1600, bytes: 320), BlockDmaVector(address: 512, bytes: 320),
      BlockDmaVector(address: 1000, bytes: 320), BlockDmaVector(address: 1280, bytes: 320),
      BlockDmaVector(address: .max - 3, bytes: 320), BlockDmaVector(address: 4096, bytes: 319),
      BlockDmaVector(address: 4096, bytes: 321),
    ] {
      guard case .invalid = prepare(cfg, [a, v]) else { return XCTFail() }
    }
    guard case .invalid = prepare(cfg, [a, b, b], read: { _ in XCTFail() }),
      case .invalid = prepare(cfg, [a, b], read: { _ in XCTFail() }, allow: { _, _, _ in false }),
      case .invalid = prepare(cfg, [a, b], allow: { _, _, write in !write })
    else { return XCTFail() }
  }
  func testSnapshotIsUsedOnceAndPublishesExactReadChain() {
    var seen: [UInt64] = []
    let spans = [
      BlockDmaVector(address: 1536, bytes: 192), BlockDmaVector(address: 4096, bytes: 320),
    ]
    guard
      case .ready(let p) = prepare(
        config()!, spans, read: { seen.append($0) },
        allow: { addr, n, write in
          addr == 512
            ? n == 32 && !write
            : write && ((addr == 1536 && n == 192) || (addr == 4096 && n == 320))
        })
    else { return XCTFail() }
    var q = SplitQueue()
    var addresses: [UInt64] = []
    var lengths: [UInt32] = []
    var flags: [UInt16] = []
    XCTAssertTrue(q.initialize(4))
    XCTAssertTrue(
      p.submit(
        &q,
        storeHeader: { _, kind, lba in
          XCTAssertEqual(kind, 0)
          XCTAssertEqual(lba, 2)
        },
        storeRange: { _, _, _, _ in XCTFail() }, setStatus: { _, b in XCTAssertEqual(b, 255) },
        descriptor: { _, addr, n, f, _ in
          addresses.append(addr)
          lengths.append(n)
          flags.append(f)
        },
        putAvailable: { _, _ in }, releaseAvailable: { _ in }))
    XCTAssertEqual(seen, [512, 528])
    XCTAssertEqual(addresses, [1024, 1536, 4096, 1280])
    XCTAssertEqual(lengths, [16, 192, 320, 1])
    XCTAssertEqual(flags, [1, 3, 3, 2])
    XCTAssertNil(p.complete(cookie: 4, status: 0, written: 193))
    XCTAssertEqual(p.complete(cookie: 4, status: 0, written: 513)?.id, 4)
  }
}
