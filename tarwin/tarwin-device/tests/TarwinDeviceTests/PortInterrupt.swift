import TarwinDevice
import TarwinIPC
import TarwinIoCompletion
import XCTest

struct IrqTestPorts: IoPorts, ~Copyable {
  var p: CompletionPort, refs = 0, woken = 0
  mutating func retainPort(_ n: UInt64) -> Bool {
    guard n == 19 else { return false }
    refs += 1
    return true
  }
  mutating func withLockedPort(_ n: UInt64, _ visit: (inout CompletionPort) -> Void) {
    XCTAssertEqual(n, 19)
    visit(&p)
  }
  mutating func releasePort(_ n: UInt64) { refs -= 1 }
  mutating func wakePort(_ n: UInt64, count: Int) { woken += count }
}
final class PortInterruptTests: XCTestCase {
  func testReserveBeforeUnmaskAndRetainCancelledVectorUntilDrained() {
    var slab = [PortSlot()]
    slab.withUnsafeMutableBufferPointer { storage in
      var ports = IrqTestPorts(p: CompletionPort(storage: storage)!)
      var irq = PortInterrupt(object: 33, epoch: 2, vector: 7)
      XCTAssertTrue(ports.p.post(PortPacket()))
      XCTAssertFalse(irq.arm(epoch: 2, port: 19, key: 8, ports: &ports) { XCTFail() })
      XCTAssertEqual(ports.refs, 0)
      _ = ports.p.take()
      var enabled = 0
      var masked = 0
      XCTAssertTrue(irq.arm(epoch: 2, port: 19, key: 8, ports: &ports) { enabled += 1 })
      XCTAssertTrue(irq.interrupt(at: 11, ports: &ports) { masked += 1 })
      XCTAssertEqual(masked, 1)
      XCTAssertFalse(irq.arm(epoch: 2, port: 19, key: 9, ports: &ports) { XCTFail() })
      let packet = ports.p.take()!
      XCTAssertEqual(packet.key, 8)
      XCTAssertEqual(packet.kind, 11)
      XCTAssertEqual(packet.result0, 7)
      XCTAssertFalse(irq.arm(epoch: 1, port: 19, key: 9, ports: &ports) { XCTFail() })
      XCTAssertTrue(irq.arm(epoch: 2, port: 19, key: 9, ports: &ports) { enabled += 1 })
      var token: PortOperation?
      XCTAssertEqual(ports.p.cancel(key: 9) { token = $0 }, 1)
      XCTAssertTrue(irq.matches(port: 19, operation: token!))
      XCTAssertFalse(irq.matches(port: 1, operation: token!))
      XCTAssertFalse(irq.revoke(at: 13, ports: &ports, maskAndDrain: { false }))
      XCTAssertNil(ports.p.take())
      XCTAssertEqual(ports.refs, 1)
      XCTAssertTrue(irq.revoke(at: 14, ports: &ports, maskAndDrain: { true }))
      XCTAssertEqual(ports.p.take()?.error, 26)
      XCTAssertEqual(ports.refs, 0)
      XCTAssertEqual(ports.woken, 2)
      XCTAssertEqual(enabled, 2)
    }
  }
}
