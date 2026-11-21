import TarwinIPC
import XCTest

final class CompletionPortTests: XCTestCase {
  func testPerObjectOrderAndCollidingBuckets() {
    var slab = [PortSlot](repeating: PortSlot(), count: 4)
    slab.withUnsafeMutableBufferPointer { storage in
      var port = CompletionPort(storage: storage)!
      let a = port.reserve(object: 1, key: 1, kind: 2)!
      let b = port.reserve(object: 5, key: 2, kind: 2)!
      let c = port.reserve(object: 1, key: 3, kind: 1)!
      let d = port.reserve(object: 1, key: 4, kind: 2)!
      XCTAssertFalse(port.post(PortPacket()))
      XCTAssertEqual(port.finish(c, at: 10) { PortPacket() }, 0)
      XCTAssertEqual(port.finish(d, at: 11) { PortPacket() }, 0)
      XCTAssertEqual(port.finish(b, at: 12) { PortPacket() }, 1)
      XCTAssertEqual(port.take()?.key, 2)
      let e = port.reserve(object: 9, key: 5, kind: 1)!
      XCTAssertEqual(
        port.finish(b, at: 13) {
          XCTFail("recycled slot")
          return PortPacket()
        }, 0)
      XCTAssertEqual(port.finish(a, at: 14) { PortPacket() }, 3)
      XCTAssertEqual(port.finish(e, at: 15) { PortPacket() }, 1)
      XCTAssertEqual((0..<4).compactMap { _ in port.take()?.key }, [1, 3, 4, 5])
      XCTAssertNil(port.take())
    }
  }

  func testCancelWaitsForProviderAndDoesNotInstallResults() {
    var slab = [PortSlot](repeating: PortSlot(), count: 3)
    slab.withUnsafeMutableBufferPointer { storage in
      var port = CompletionPort(storage: storage)!
      let a = port.reserve(object: 1, key: 99, kind: 1)!
      let b = port.reserve(object: 2, key: 99, kind: 3)!
      let c = port.reserve(object: 3, key: 98, kind: 4)!
      var scheduled: [PortOperation] = []
      XCTAssertEqual(port.cancel(key: 99) { scheduled.append($0) }, 2)
      XCTAssertEqual(scheduled, [a, b])
      XCTAssertEqual(port.cancel(key: 99) { _ in XCTFail("duplicate cancel") }, 0)
      XCTAssertNil(port.take())
      for (op, kind) in [(b, UInt32(3)), (a, UInt32(1))] {
        XCTAssertEqual(
          port.finish(op, at: 77) {
            XCTFail("cancelled")
            return PortPacket()
          }, 1)
        let p = port.take()!
        XCTAssertEqual(p.key, 99)
        XCTAssertEqual(p.error, 26)
        XCTAssertEqual(p.subsystem, 1)
        XCTAssertEqual(p.kind, kind)
        XCTAssertEqual(p.result0, 0)
        XCTAssertEqual(p.timestamp, 77)
      }
      port.close()
      XCTAssertEqual(
        port.finish(c, at: 78) {
          XCTFail("closed")
          return PortPacket()
        }, 0)
      XCTAssertNil(port.reserve(object: 1, key: 1, kind: 4))
      XCTAssertFalse(port.post(PortPacket()))
    }
  }

  func testRingPressureKeepsPacketAndWireFields() {
    let memory = SharedMemory(stride: 64)
    defer { withExtendedLifetime(memory) {} }
    var p = RingEndpoint(fresh: memory.view, completion: true, producer: true)!
    var c = RingEndpoint(fresh: memory.view, completion: true, producer: false)!
    var submission = RingEndpoint(fresh: memory.view, completion: false, producer: true)!
    var slab = [PortSlot()]
    slab.withUnsafeMutableBufferPointer { storage in
      var port = CompletionPort(storage: storage)!
      var user = PortPacket()
      user.kind = 9
      for i in 0..<64 {
        user.key = UInt64(i)
        XCTAssertTrue(port.post(user))
        XCTAssertEqual(port.publishNext(to: &p), .transferred(notifyPeer: false))
      }
      let op = port.reserve(object: 1, key: 0x1234_5678_0000_0000, kind: 11)!
      user.error = 4
      user.subsystem = 10
      user.errorFlags = 1
      user.detail = 0x1122_3344_5566_7788
      user.result0 = 99
      user.result1 = 73
      user.aux = 88
      XCTAssertEqual(port.finish(op, at: 999) { user }, 1)
      XCTAssertEqual(port.publishNext(to: &submission), .wrongSide)
      XCTAssertEqual(port.publishNext(to: &p), .wait)
      XCTAssertEqual(port.available, 1)
      var r = RingRecord()
      for i in 0..<64 {
        XCTAssertEqual(c.pop(into: &r), .transferred(notifyPeer: true))
        XCTAssertEqual(r.words[0], UInt32(i))
        XCTAssertEqual(r.words[6], 0)
      }
      XCTAssertEqual(port.publishNext(to: &p), .transferred(notifyPeer: false))
      XCTAssertEqual(port.available, 0)
      XCTAssertEqual(c.pop(into: &r), .transferred(notifyPeer: false))
      XCTAssertEqual(
        (0..<16).map { r.words[$0] },
        [
          0, 0x1234_5678, 4, 0x1000a, 0x5566_7788, 0x1122_3344, 11, 0, 0, 0, 73, 0, 88, 0, 999, 0,
        ])
      XCTAssertNil(port.publishNext(to: &p))
    }
  }
}
