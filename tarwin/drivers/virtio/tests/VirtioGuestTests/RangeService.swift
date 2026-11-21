import TarwinBlockWire
import TarwinIPC
import VirtioBlockService
import VirtioGuest
import XCTest

final class RangeServiceTests: XCTestCase {
  func device() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 57)
    b[0] = 64
    b[36] = 16
    b[40] = 2
    b[44] = 4
    b[48] = 8
    b[52] = 1
    b[56] = 1
    return b
  }
  func testSnapshotReadsOnlyNegotiatedFieldsAndRetriesTornConfiguration() {
    let bytes = device()
    var seq = 0
    var first = true
    let c = BlockConfiguration.snapshot(
      features: 0x6000, configBytes: 57, generation: { UInt32(seq) },
      read: { i in
        if i == 2 && first {
          first = false
          seq += 1
          return 0xff
        }
        return bytes[i]
      })
    XCTAssertEqual(c?.capacity, 64)
    XCTAssertEqual(c?.discard?.alignment, 4)
    XCTAssertEqual(c?.zero?.mayUnmap, true)
    XCTAssertNil(
      BlockConfiguration.snapshot(
        features: 0x4000, configBytes: 56, generation: { 0 },
        read: { _ in
          XCTFail()
          return 0
        }))
    var gen: UInt32 = 0
    XCTAssertNil(
      BlockConfiguration.snapshot(
        features: 0, configBytes: 8,
        generation: {
          gen += 1
          return gen
        },
        read: {
          XCTAssertLessThan($0, 8)
          return bytes[$0]
        }))
    XCTAssertEqual(gen, 16)
  }
  func testRangeDescriptorUsesPrivateScratchAndNoClientVector() throws {
    let bytes = device()
    let cfg = try XCTUnwrap(
      BlockConfiguration.snapshot(
        features: 0x6000, configBytes: 57, generation: { 42 }, read: { bytes[$0] }))
    func prepare(_ op: BlockOp, _ lba: UInt64, _ n: UInt64, _ scratch: UInt64?) -> DriverRequest {
      let r = BlockRequest(
        id: 8, epoch: 1, lba: lba, blocks: n, queue: 0, op: op, qos: .standard,
        payload: BlockPayload())!
      return prepareBlockIo(
        r.record(), epoch: 1, queue: 0, config: cfg, header: 128, status: 255, rangeBuffer: scratch,
        allows: { _, _, _ in
          XCTFail()
          return false
        },
        readVector: { _ in
          XCTFail()
          return nil
        })
    }
    if case .unsupported = prepare(.discard, 3, 4, 4096) {} else { XCTFail() }
    if case .unsupported = prepare(.zero, 56, 9, 4096) {} else { XCTFail() }
    if case .invalid = prepare(.zero, 4, 8, nil) {} else { XCTFail() }
    for op: BlockOp in [.discard, .zero] {
      guard case .ready(let p) = prepare(op, 56, 8, 4096) else { return XCTFail() }
      var q = SplitQueue()
      XCTAssertTrue(q.initialize(4))
      var ranges = 0
      XCTAssertTrue(
        p.submit(
          &q,
          storeHeader: { a, k, s in
            XCTAssertEqual(a, 128)
            XCTAssertEqual(k, op == .discard ? 11 : 13)
            XCTAssertEqual(s, 0)
          },
          storeRange: { a, s, n, f in
            XCTAssertEqual(a, 4096)
            XCTAssertEqual(s, 56)
            XCTAssertEqual(n, 8)
            XCTAssertEqual(f, 0)
            ranges += 1
          }, setStatus: { _, _ in }, descriptor: { _, _, _, _, _ in }, putAvailable: { _, _ in },
          releaseAvailable: { _ in }))
      XCTAssertEqual(ranges, 1)
      XCTAssertNil(p.complete(cookie: 8, status: 0, written: 16))
      XCTAssertEqual(p.complete(cookie: 8, status: 0, written: 1)?.status, .ok)
    }
  }
}
