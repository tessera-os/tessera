import TarwinABI
import TarwinDevice
import TarwinIPC
import TarwinObject
import TarwinSyscall
import XCTest

private final class IrqWorker: InterruptCallContext {
  let table: HandleReadView, header: UnsafePointer<ObjectHeader>
  var process: UInt64 = 7, disconnected = false, enabled = 0
  var slot: DeviceSlotState, line: BoundDriverInterrupt, ports: IrqTestPorts
  init(table: HandleReadView, object: UnsafePointer<ObjectHeader>, ports: consuming IrqTestPorts) {
    self.table = table
    header = object
    self.ports = consume ports
    var slot = DeviceSlotState(group: 3)
    precondition(slot.assign(true, 7) { _, _ in true })
    self.slot = slot
    line = BoundDriverInterrupt(
      object: object.pointee.koid, slot: slot, vector: 29, port: 19, key: 8)!
  }
  func pinCaller(_ visit: (UInt64, HandleReadView) -> PinResult) -> PinResult {
    visit(process, table)
  }
  func retire(_ header: UnsafePointer<ObjectHeader>) { XCTFail() }
  func withLockedLine(_ object: UnsafePointer<ObjectHeader>, rearm: borrowing InterruptRearm)
    -> UInt32
  {
    guard !disconnected, object == header else { return 70 }
    return rearm.apply(to: &line, slot: slot, ports: &ports) { enabled += 1 }
  }
}
final class InterruptCallTests: XCTestCase {
  func testDeliveryOnlyRearmsTheRegisteredEpochAndPort() {
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 3)
    let headers = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 2)
    let packets = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
    let h = headers.baseAddress!
    let ids = KoidSource()
    var table = HandleTable(storage: cells, salt: 55)!
    packets.initialize(repeating: PortSlot())
    for (i, k) in [TarwinKind.interrupt, TarwinKind.deviceSlot].enumerated() {
      (h + i).initialize(to: ObjectHeader(source: ids, ownerJob: 1, kind: k, maximumRights: 127)!)
    }
    defer {
      table.drain { _ in XCTFail() }
      for i in headers.indices { XCTAssertEqual((h + i).pointee.release(), .destroy) }
      headers.deinitialize()
      headers.deallocate()
      cells.deinitialize()
      cells.deallocate()
      packets.deinitialize()
      packets.deallocate()
    }
    guard case .installed(let name) = table.install(h, rights: 64),
      case .installed(let denied) = table.install(h, rights: 4),
      case .installed(let wrong) = table.install(h + 1, rights: 64)
    else { return XCTFail() }
    let worker = IrqWorker(
      table: table.reader, object: .init(h),
      ports: IrqTestPorts(p: CompletionPort(storage: packets)!))
    var provider = InterruptCompleteCall(worker)
    func call(_ handle: UInt64, _ isa: CallISA = .x64) -> UInt32 {
      var scratch = [UInt64](repeating: 0, count: 6)
      return scratch.withUnsafeMutableBufferPointer {
        switch dispatchCall(
          isa: isa, savedPC: 0x1000 + (isa == .rv64 ? 0 : isa.instructionWidth),
          libraryCode: 0x1000..<0x2000, userRange: 0..<0, number: TarwinCall.interruptComplete,
          registers: .init(handle),
          scratch: $0, provider: &provider)
        {
        case .returned(let r): return r.code
        default:
          XCTFail()
          return .max
        }
      }
    }
    XCTAssertEqual(call(0), 2)
    XCTAssertEqual(call(wrong), 3)
    XCTAssertEqual(call(denied), 4)
    XCTAssertEqual(call(name), 23)
    XCTAssertTrue(
      worker.line.activate(slot: worker.slot, ports: &worker.ports) { worker.enabled += 1 })
    var masked = 0
    for arch: CallISA in [.aarch64, .x64, .rv64] {
      XCTAssertTrue(worker.line.interrupt(at: 2, ports: &worker.ports) { masked += 1 })
      XCTAssertFalse(worker.line.interrupt(at: 3, ports: &worker.ports) { XCTFail() })
      XCTAssertEqual(call(name), 24)
      let p = worker.ports.p.take()
      XCTAssertEqual(p?.kind, 11)
      XCTAssertEqual(p?.key, 8)
      XCTAssertEqual(p?.result0, 29)
      worker.process = 8
      XCTAssertEqual(call(name), 4)
      worker.process = 7
      XCTAssertEqual(call(name, arch), 0)
      XCTAssertEqual(call(name), 23)
    }
    XCTAssertEqual(worker.enabled, 4)
    XCTAssertEqual(masked, 3)
    XCTAssertTrue(worker.line.interrupt(at: 4, ports: &worker.ports) { masked += 1 })
    _ = worker.ports.p.take()
    XCTAssertFalse(worker.line.revoke(at: 5, ports: &worker.ports) { false })
    XCTAssertEqual(call(name), 23)
    XCTAssertTrue(worker.line.revoke(at: 6, ports: &worker.ports) { true })
    XCTAssertEqual(call(name), 70)
    XCTAssertTrue(worker.slot.revoke(false, { true }, { true }, { true }, { true }))
    XCTAssertTrue(worker.slot.assign(true, 7) { _, _ in true })
    XCTAssertEqual(call(name), 4)
    worker.disconnected = true
    XCTAssertEqual(call(name), 70)
    XCTAssertTrue(table.close(name) { _ in XCTFail() })
    XCTAssertEqual(call(name), 2)
    XCTAssertEqual(worker.ports.refs, 0)
  }
}
