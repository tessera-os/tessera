import TarwinBlockWire
import TarwinIPC
import VirtioBlockService
import XCTest

final class BlockServiceTests: XCTestCase {
  func testRejectsUnmappedListBeforeReadingItAndNeverDowngradesFua() {
    func record(_ op: BlockOp) -> RingRecord {
      BlockRequest(
        id: 17, epoch: 3, lba: 7, blocks: 1, queue: 0, op: op, qos: .interactive,
        payload: BlockPayload(list: 4096, vectors: 1))!.record()
    }
    if case .invalid = prepareBlockIo(
      record(.read), epoch: 3, queue: 0, capacitySectors: 64, features: 512, header: 32, status: 64,
      allows: { _, _, _ in false },
      readVector: { _ in
        XCTFail()
        return nil
      })
    {
    } else {
      XCTFail()
    }
    guard
      case .unsupported(let refusal) = prepareBlockIo(
        record(.fua), epoch: 3, queue: 0, capacitySectors: 64, features: 512, header: 32,
        status: 64,
        allows: { _, _, _ in
          XCTFail()
          return false
        },
        readVector: { _ in
          XCTFail()
          return nil
        })
    else { return XCTFail() }
    XCTAssertEqual(refusal.id, 17)
    XCTAssertEqual(refusal.status, .unsupported)
    guard
      case .ready(let p) = prepareBlockIo(
        record(.read), epoch: 3, queue: 0, capacitySectors: 64, features: 512, header: 32,
        status: 64,
        allows: { addr, _, write in write ? addr == 8192 : addr == 4096 },
        readVector: { _ in BlockDmaVector(address: 8192, bytes: 512) })
    else { return XCTFail() }
    XCTAssertNil(p.complete(cookie: 18, status: 0, written: 513))
    XCTAssertNil(p.complete(cookie: 17, status: 0, written: 512))
    XCTAssertEqual(p.complete(cookie: 17, status: 0, written: 513)?.epoch, 3)
  }
}
