import TarwinDevice
import TarwinIPC
import TarwinNet
import TarwinNetWire
import XCTest

final class NetRingTests: XCTestCase {
  func testPinsStayOwnedAcrossFailedDrainAndStaleCompletion() {
    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
    defer { raw.deallocate() }
    let m = IoRingMapping(initializing: raw, count: 64, stride: 64)!
    var producer = m.endpoint(completion: false, producer: true)!
    var consumer = m.endpoint(completion: false, producer: false)!
    let slots = UnsafeMutableBufferPointer<RxSlot>.allocate(capacity: 2)
    slots.initialize(repeating: RxSlot())
    defer {
      slots.deinitialize()
      slots.deallocate()
    }
    var q = InterfaceRxQueue(queue: 4, maximum: 1514, slots: slots)!
    for pin: UInt64 in [31, 32] {
      XCTAssertEqual(
        q.post(pin: pin, iova: pin * 4096, ring: &producer), .transferred(notifyPeer: false))
    }
    XCTAssertEqual(q.post(pin: 31, iova: 9, ring: &producer), .wait)
    var r = RingRecord()
    _ = consumer.pop(into: &r)
    let f = NetFrame(record: r)!
    let c = NetFrameDone(direction: .receive, queue: 4, id: f.id, epoch: f.epoch, bytes: 1514)!
      .record()
    var invalid = c
    invalid.words[6] = 1515
    XCTAssertNil(q.receive(invalid))
    XCTAssertEqual(q.receive(c), f.id)
    XCTAssertNil(q.receive(c))
    XCTAssertFalse(q.deliver(id: f.id, sync: { _ in false }, consume: { _, _ in XCTFail() }))
    var reclaimed: [UInt64] = []
    q.stop()
    XCTAssertFalse(q.recover(removed: false, drain: { false }, reclaim: { reclaimed.append($0) }))
    XCTAssertEqual(reclaimed, [])
    XCTAssertTrue(q.recover(removed: false, drain: { true }, reclaim: { reclaimed.append($0) }))
    XCTAssertEqual(reclaimed, [31, 32])
    XCTAssertNil(q.receive(c))
    XCTAssertEqual(q.epoch, 2)
  }
  func testWrongTransmitQueueCannotRetirePin() {
    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
    defer { raw.deallocate() }
    let m = IoRingMapping(initializing: raw, count: 64, stride: 64)!
    var producer = m.endpoint(completion: false, producer: true)!
    let slots = UnsafeMutableBufferPointer<TxSlot>.allocate(capacity: 1)
    let flows = UnsafeMutableBufferPointer<TxFlow>.allocate(capacity: 1)
    slots.initialize(repeating: TxSlot())
    flows.initialize(repeating: TxFlow())
    defer {
      slots.deinitialize()
      slots.deallocate()
      flows.deinitialize()
      flows.deallocate()
    }
    var q = InterfaceTxQueue(packets: slots, flows: flows)
    let id = q.enqueue(
      TxPacket(
        process: 1, flow: 2, memory: 3, offset: 2, bytes: 60, notBefore: 0, background: false),
      allowed: { _, _ in true }, pin: { _, _, _, _ in 77 })
    XCTAssertEqual(
      q.publish(queue: 3, now: 1, congested: false, iova: { _, _, _, _ in 4096 }, ring: &producer),
      .transferred(notifyPeer: false))
    func c(_ ring: UInt32) -> RingRecord {
      NetFrameDone(direction: .transmit, queue: ring, id: id, epoch: 1, bytes: 60)!.record()
    }
    XCTAssertFalse(
      q.finish(
        queue: 2, record: c(2),
        retireMapping: { _ in
          XCTFail()
          return true
        }, done: { _, _, _ in XCTFail() }))
    XCTAssertFalse(q.complete(epoch: 1, key: id, retire: { _, _, _ in XCTFail() }))
    XCTAssertFalse(
      q.finish(
        queue: 3, record: c(3), retireMapping: { _ in false }, done: { _, _, _ in XCTFail() }))
    XCTAssertTrue(
      q.finish(
        queue: 3, record: c(3), retireMapping: { $0 == 77 },
        done: { k, p, d in
          XCTAssertEqual(k, id)
          XCTAssertEqual(p, 77)
          XCTAssertEqual(d, .transmitted)
        }))
  }
}
