import LibTesseraTarwin
import TarwinABI
import TarwinObject
import TarwinObjectCalls
import TarwinSyscall
import XCTest

private struct Lifecycle: HandleRetirement {
  var retired: [UInt64] = [], invalidated: [UInt64] = []
  mutating func retire(_ header: UnsafePointer<ObjectHeader>) {
    retired.append(header.pointee.koid)
  }
  mutating func invalidate(_ name: UInt64) { invalidated.append(name) }
}

private final class ProcessFixture: HandleCallContext {
  let storage = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 32)
  let header = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  var table: HandleTable
  var lifecycle = Lifecycle()
  var input = UnsafeBufferPointer<UInt64>(start: nil, count: 0)
  var output = UnsafeMutableBufferPointer<UInt64>(start: nil, count: 0)
  let userRange: Range<UInt64> = 0x1000..<UInt64.max
  var holding = false
  init() {
    table = HandleTable(storage: storage, salt: 31)!
    header.initialize(
      to: ObjectHeader(source: KoidSource(), ownerJob: 1, kind: TarwinKind.port, maximumRights: 7)!)
  }
  deinit {
    table.drain { _ in XCTFail("boot reference still live") }
    XCTAssertEqual(header.pointee.release(), .destroy)
    storage.deinitialize()
    storage.deallocate()
    header.deinitialize(count: 1)
    header.deallocate()
  }
  func name() -> UInt64 {
    guard case .installed(let n) = table.install(header, rights: 7) else {
      XCTFail()
      return 0
    }
    return n
  }
  func withWriter<R>(_ body: (inout HandleTable, inout Lifecycle) -> R) -> R {
    XCTAssertFalse(holding)
    holding = true
    defer { holding = false }
    return body(&table, &lifecycle)
  }
  // Single-threaded fixture: storage stays mapped for the entire invocation.
  func withRead<R>(_ body: (HandleReadView, inout Lifecycle) -> R) -> R {
    XCTAssertFalse(holding)
    holding = true
    defer { holding = false }
    return body(table.reader, &lifecycle)
  }
  func readWords(from address: UInt64, into dst: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    XCTAssertFalse(holding)
    let base = UInt64(UInt(bitPattern: input.baseAddress))
    guard address >= base, address - base <= UInt64(input.count * 8), (address - base) % 8 == 0
    else { return false }
    let start = Int((address - base) / 8)
    guard dst.count <= input.count - start else { return false }
    for i in dst.indices { dst[i] = input[start + i] }
    return true
  }
  func writeWords(to address: UInt64, from src: UnsafeBufferPointer<UInt64>) -> Bool {
    XCTAssertFalse(holding)
    guard address == UInt64(UInt(bitPattern: output.baseAddress)), src.count <= output.count else {
      return false
    }
    for i in src.indices { output[i] = src[i] }
    return true
  }
}

private struct Gate: NativeGate {
  let isa: CallISA
  var provider: HandleCalls<ProcessFixture>
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    var scratch = [UInt64](repeating: 0, count: 8)
    let result = scratch.withUnsafeMutableBufferPointer {
      dispatchCall(
        isa: isa, savedPC: isa == .rv64 ? 0x1000 : 0x1000 + isa.instructionWidth,
        libraryCode: 0x1000..<0x1010, userRange: provider.context.userRange, number: number,
        registers: registers, scratch: $0, provider: &provider)
    }
    guard case .returned(let status) = result else {
      XCTFail("unexpected origin rejection")
      return CallResult(status: .max)
    }
    return status
  }
}

final class HandleCallTests: XCTestCase {
  func testAllFiveHandleCallsAcrossTheTransport() {
    for isa in [CallISA.aarch64, .x64, .rv64] {
      let proc = ProcessFixture()
      var gate = Gate(isa: isa, provider: HandleCalls(context: proc))
      let name = proc.name()
      XCTAssertEqual(NativeHandles.duplicate(name, rights: 8, gate: &gate).code, 4)
      let dup = NativeHandles.duplicate(name, rights: .max, gate: &gate)
      XCTAssertEqual(dup.status, 0)
      let reduced = NativeHandles.replace(dup.first, rights: 4, gate: &gate)
      XCTAssertEqual(reduced.status, 0)
      XCTAssertEqual(NativeHandles.close(dup.first, gate: &gate).code, 2)
      XCTAssertEqual(NativeHandles.duplicate(reduced.first, rights: .max, gate: &gate).code, 4)
      var output = [UInt64](repeating: .max, count: 4)
      output.withUnsafeMutableBufferPointer {
        XCTAssertEqual(NativeHandles.info(reduced.first, into: $0, gate: &gate).code, 1)
        proc.output = $0
        defer { proc.output = .init(start: nil, count: 0) }
        XCTAssertEqual(NativeHandles.info(reduced.first, into: $0, gate: &gate).status, 0)
      }
      XCTAssertEqual(output, [UInt64(TarwinKind.port), 4, proc.header.pointee.koid, 0])
      let batch = [name, UInt64(0), reduced.first] + (0..<12).map { _ in proc.name() }
      batch.withUnsafeBufferPointer {
        XCTAssertEqual(NativeHandles.closeMany($0, gate: &gate).code, 1)
        proc.input = $0
        defer { proc.input = .init(start: nil, count: 0) }
        XCTAssertEqual(NativeHandles.closeMany($0, gate: &gate).code, 2)
      }
      XCTAssertEqual(proc.table.freeCount, 32)
      XCTAssertEqual(proc.lifecycle.invalidated, [dup.first] + batch.filter { $0 != 0 })
      XCTAssertEqual(NativeHandles.close(proc.name(), gate: &gate).code, 0)
      XCTAssertTrue(proc.lifecycle.retired.isEmpty)
    }
  }
}
