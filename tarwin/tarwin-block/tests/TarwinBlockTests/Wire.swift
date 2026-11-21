import TarwinBlockWire
import TarwinIPC
import XCTest

@testable import TarwinBlock

final class BlockWireTests: XCTestCase {
  func request(
    _ op: BlockOp, at: UInt64 = 8, count: UInt64 = 8, vector: Bool = true, zone: ZoneAction = .none
  ) -> BlockRequest {
    BlockRequest(
      id: 1, epoch: 2, lba: at, blocks: count, queue: 3, op: op, qos: .interactive,
      payload: BlockPayload(list: vector ? 0x1000 : 0, vectors: vector ? 1 : 0, zone: zone))!
  }
  func testRejectsReservedFieldsWrongQueueEpochAndInvalidCompletionStatus() {
    let r = request(.fua)
    var row = r.record()
    XCTAssertEqual(BlockRequest(record: row, epoch: 2, queue: 3)?.op, .fua)
    XCTAssertNil(BlockRequest(record: row, epoch: 1, queue: 3))
    XCTAssertNil(BlockRequest(record: row, epoch: 2, queue: 4))
    row.words[31] = 1
    XCTAssertNil(BlockRequest(record: row, epoch: 2, queue: 3))
    var completion = BlockCompletion(id: 1, epoch: 2, queue: 3, status: .media).record()
    XCTAssertEqual(BlockCompletion(record: completion)?.status, .media)
    completion.words[0] = 0xff0001
    XCTAssertNil(BlockCompletion(record: completion))
  }
  func testAtomicZonesAndVectorGrantsMustMatchRegisteredGeometry() {
    let limits = BlockLimits(
      capacity: 64, blockBytes: 512, maxVectors: 4, flush: true, fua: false, discard: true,
      zero: false, readOnly: false, atomicUnit: 8, zoneBlocks: 16)!
    XCTAssertTrue(limits.supports(request(.atomic)))
    XCTAssertFalse(limits.supports(request(.atomic, at: 3)))
    XCTAssertFalse(limits.supports(request(.fua)))
    XCTAssertFalse(limits.supports(request(.zero, vector: false)))
    XCTAssertTrue(limits.supports(request(.zone, at: 0, count: 16, vector: false, zone: .reset)))
    XCTAssertFalse(limits.supports(request(.zone, at: 0, count: 8, vector: false, zone: .reset)))
    let r = request(.read)
    let allow: (UInt64, UInt64, Bool) -> Bool = { addr, n, w in
      (addr == 0x1000 && n == 16 && !w) || (addr == 0x2000 && n == 4096 && w)
    }
    func check(_ addr: UInt64, _ n: UInt32, _ f: (UInt64, UInt64, Bool) -> Bool) -> Bool {
      [BlockDmaVector(address: addr, bytes: n)].withUnsafeBufferPointer {
        limits.checkVectors(r, snapshot: $0, validate: f)
      }
    }
    XCTAssertTrue(check(0x2000, 4096, allow))
    XCTAssertFalse(check(0x2000, 4096) { _, _, _ in false })
    XCTAssertFalse(check(0x1008, 4096) { _, _, _ in true })
    XCTAssertFalse(check(.max - 10, 4096) { _, _, _ in true })
    XCTAssertFalse(check(0x2000, 1024) { _, _, _ in true })
  }
}
