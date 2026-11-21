import TarwinABI
import TarwinDevice
import TarwinObject
import TarwinSyscall
import XCTest

private struct Registers: SlotConfigSpace {
  var value: UInt32 = 0x42, reads = 0, writes = 0
  func policy(offset: UInt32, width: UInt32) -> ConfigPolicy {
    ConfigPolicy(writable: offset == 0x80 && width == 1 ? 3 : 0, plainReadWrite: offset == 0x80)
  }
  mutating func read(offset: UInt32, width: UInt32) -> ConfigReply {
    reads += 1
    return .value(value)
  }
  mutating func write(offset: UInt32, width: UInt32, value: UInt32) -> Bool {
    writes += 1
    self.value = value
    return true
  }
}

private struct Context: SlotConfigContext {
  let table: HandleReadView, header: UnsafePointer<ObjectHeader>
  var process: UInt64 = 7, epoch: UInt64 = 1
  var slot = DeviceSlotState(group: 3), space = Registers()
  var disconnected = false
  func pinCaller(_ visit: (UInt64, HandleReadView) -> PinResult) -> PinResult {
    visit(process, table)
  }
  mutating func retire(_ header: UnsafePointer<ObjectHeader>) { XCTFail("slot still owned") }
  mutating func withConfig(
    _ header: UnsafePointer<ObjectHeader>,
    _ visit: (UInt64, DeviceSlotState, inout Registers) -> ConfigReply
  ) -> ConfigReply {
    guard !disconnected, header == self.header else { return .fault }
    return visit(epoch, slot, &space)
  }
}

final class ConfigCallTests: XCTestCase {
  func testDispatchKeepsSlotAuthorityAndFiltersWrites() {
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 3)
    let h = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 2)
    var table = HandleTable(storage: cells, salt: 91)!
    let ids = KoidSource()
    for (i, k) in [TarwinKind.deviceSlot, TarwinKind.port].enumerated() {
      (h + i).initialize(to: ObjectHeader(source: ids, ownerJob: 1, kind: k, maximumRights: 516)!)
    }
    defer {
      table.drain { _ in XCTFail() }
      for i in 0..<2 { XCTAssertEqual((h + i).pointee.release(), .destroy) }
      h.deinitialize(count: 2)
      h.deallocate()
      cells.deinitialize()
      cells.deallocate()
    }
    guard case .installed(let name) = table.install(h, rights: 516),
      case .installed(let readonly) = table.install(h, rights: 4),
      case .installed(let port) = table.install(h + 1, rights: 516)
    else { return XCTFail() }
    var abi = DeviceConfigCalls(Context(table: table.reader, header: UnsafePointer(h)))
    XCTAssertTrue(abi.context.slot.assign(true, 7, { _, _ in true }))
    let read = TarwinCall.deviceSlotConfigRead
    let write = TarwinCall.deviceSlotConfigWrite
    func call(_ nr: UInt64, _ regs: CallRegisters, isa: CallISA = .x64) -> CallResult {
      var scratch = [UInt64](repeating: 0, count: 8)
      return scratch.withUnsafeMutableBufferPointer {
        switch dispatchCall(
          isa: isa, savedPC: 0x1000 + (isa == .rv64 ? 0 : isa.instructionWidth),
          libraryCode: 0x1000..<0x2000, userRange: 0..<0, number: nr, registers: regs, scratch: $0,
          provider: &abi)
        {
        case .returned(let r): return r
        default:
          XCTFail()
          return CallResult(status: .max)
        }
      }
    }
    for arch: CallISA in [.aarch64, .x64, .rv64] {
      XCTAssertEqual(call(read, .init(readonly, 0x80, 1), isa: arch).first, 0x42)
    }
    XCTAssertEqual(call(write, .init(readonly, 0x80, 1, 0x43)).code, 4)
    XCTAssertEqual(call(read, .init(port, 0x80, 1)).code, 3)
    XCTAssertEqual(call(read, .init(name, 0x101, 4)).code, 1)
    XCTAssertEqual(call(write, .init(name, 0x10, 4, 0)).code, 4)
    XCTAssertEqual(call(write, .init(name, 0x88, 1, 0)).code, 4)
    XCTAssertEqual(abi.context.space.reads, 3)
    XCTAssertEqual(call(write, .init(name, 0x80, 1, 0xff)).code, 4)
    XCTAssertEqual(call(write, .init(name, 0x80, 1, 0x43)).code, 0)
    XCTAssertEqual(abi.context.space.writes, 1)
    XCTAssertEqual(call(read, .init(name, 0x80, 1)).first, 0x43)
    let reads = abi.context.space.reads
    abi.context.process = 8
    XCTAssertEqual(call(read, .init(name, 0, 4)).code, 4)
    abi.context.process = 7
    XCTAssertTrue(abi.context.slot.revoke(false, { true }, { true }, { true }, { true }))
    XCTAssertTrue(abi.context.slot.assign(true, 7, { _, _ in true }))
    XCTAssertEqual(call(read, .init(name, 0, 4)).code, 4)
    abi.context.disconnected = true
    XCTAssertEqual(call(read, .init(name, 0, 4)).code, 70)
    XCTAssertTrue(table.close(name) { _ in XCTFail() })
    XCTAssertEqual(call(read, .init(name, 0, 4)).code, 2)
    XCTAssertEqual(call(TarwinCall.deviceSlotReset, .init(readonly)).code, 10)
    XCTAssertEqual(abi.context.space.reads, reads)
    XCTAssertEqual(abi.context.space.writes, 1)
  }
}
