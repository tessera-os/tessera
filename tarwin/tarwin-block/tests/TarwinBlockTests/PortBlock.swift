import TarwinBlock
import TarwinBlockWire
import TarwinDevice
import TarwinIPC
import TarwinIoCompletion
import XCTest

private struct Ports: IoPorts, ~Copyable {
  var a: CompletionPort, b: CompletionPort, retained = 0, woken = 0
  mutating func retainPort(_ k: UInt64) -> Bool {
    guard k == 7 || k == 8 else { return false }
    retained += 1
    return true
  }
  mutating func withLockedPort(_ k: UInt64, _ visit: (inout CompletionPort) -> Void) {
    if k == 7 {
      visit(&a)
    } else {
      precondition(k == 8)
      visit(&b)
    }
  }
  mutating func releasePort(_ k: UInt64) { retained -= 1 }
  mutating func wakePort(_ k: UInt64, count: Int) { woken += count }
}
final class PortBlockTests: XCTestCase {
  func testCancellationUnderLoadWaitsForDrainAndPreservesOrderAcrossRestart() {
    let a = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 2)
    let b = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
    a.initialize(repeating: PortSlot())
    b.initialize(repeating: PortSlot())
    let slots = UnsafeMutableBufferPointer<BlockPortSlot>.allocate(capacity: 4)
    for i in slots.indices { slots.baseAddress!.advanced(by: i).initialize(to: BlockPortSlot()) }
    let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096 + 8192, alignment: 4096)
    defer {
      a.deinitialize()
      a.deallocate()
      b.deinitialize()
      b.deallocate()
      slots.deinitialize()
      slots.deallocate()
      memory.deallocate()
    }
    var ports = Ports(a: CompletionPort(storage: a)!, b: CompletionPort(storage: b)!)
    var q = PortBlockQueue(capacity: 64, blockBytes: 512, queueCount: 1, depth: 4, slots: slots)!
    var ring = IoRingMapping(initializing: memory, count: 64, stride: 64)!.endpoint(
      completion: false, producer: true)!
    func cmd(_ lba: UInt64) -> BlockCommand {
      BlockCommand(op: .read, lba: lba, blocks: 1, qos: .interactive, queue: 0)
    }
    let first = q.submit(cmd(0), object: 9, key: 101, port: 7, ports: &ports)
    let second = q.submit(cmd(1), object: 9, key: 102, port: 7, ports: &ports)
    XCTAssertNotEqual(first, 0)
    XCTAssertNotEqual(second, 0)
    XCTAssertEqual(q.submit(cmd(2), object: 9, key: 103, port: 7, ports: &ports), 0)
    let third = q.submit(cmd(2), object: 4, key: 101, port: 8, ports: &ports)
    XCTAssertNotEqual(third, 0)
    XCTAssertEqual(ports.retained, 3)
    for _ in 0..<3 {
      XCTAssertEqual(
        q.publish(
          queue: 0, payload: { _, _ in BlockPayload(list: 0x1000, vectors: 1) }, ring: &ring),
        .ring(.transferred(notifyPeer: false)))
    }
    func reply(_ id: UInt64, _ epoch: UInt64) -> RingRecord {
      BlockCompletion(id: id, epoch: epoch, queue: 0, status: .ok).record()
    }
    XCTAssertEqual(q.receive(queue: 0, record: reply(second, 1)), second)
    XCTAssertTrue(q.release(id: second, at: 10, ports: &ports, retireBuffers: { _ in true }))
    XCTAssertNil(ports.a.take())
    var cancel: PortOperation?
    XCTAssertEqual(ports.a.cancel(key: 101) { cancel = $0 }, 1)
    XCTAssertEqual(q.cancel(port: 7, operation: cancel!), first)
    XCTAssertFalse(
      q.release(
        id: first, at: 11, ports: &ports,
        retireBuffers: { _ in
          XCTFail()
          return true
        }))
    q.stop()
    XCTAssertFalse(q.recover(removed: false, drainOldBackend: { false }))
    XCTAssertNil(ports.a.take())
    XCTAssertTrue(q.recover(removed: false, drainOldBackend: { true }))
    XCTAssertEqual(q.epoch, 2)
    XCTAssertFalse(q.release(id: first, at: 12, ports: &ports, retireBuffers: { _ in false }))
    XCTAssertNil(ports.a.take())
    XCTAssertEqual(ports.retained, 2)
    XCTAssertTrue(q.release(id: first, at: 13, ports: &ports, retireBuffers: { _ in true }))
    let cancelled = ports.a.take()!
    let ok = ports.a.take()!
    XCTAssertEqual(cancelled.key, 101)
    XCTAssertEqual(cancelled.error, 26)
    XCTAssertEqual(ok.key, 102)
    XCTAssertEqual(ok.result0, 512)
    XCTAssertNil(q.receive(queue: 0, record: reply(third, 1)))
    XCTAssertNil(ports.b.take())
    XCTAssertEqual(
      q.publish(
        queue: 0,
        payload: { id, epoch in
          XCTAssertEqual(id, third)
          XCTAssertEqual(epoch, 2)
          return BlockPayload(list: 0x2000, vectors: 1)
        }, ring: &ring), .ring(.transferred(notifyPeer: false)))
    q.stop()
    XCTAssertTrue(q.recover(removed: true, drainOldBackend: { true }))
    XCTAssertTrue(q.release(id: third, at: 15, ports: &ports, retireBuffers: { _ in true }))
    let lost = ports.b.take()!
    XCTAssertEqual(lost.error, 70)
    XCTAssertEqual(lost.kind, 3)
    XCTAssertEqual(lost.key, 101)
    XCTAssertEqual(ports.retained, 0)
    XCTAssertEqual(ports.woken, 3)
  }
}
