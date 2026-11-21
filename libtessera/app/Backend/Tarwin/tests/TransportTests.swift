import LibTesseraTarwin
import TarwinABI
import TarwinSyscall
import XCTest

private struct Capture: CallProvider {
  let source: UnsafeBufferPointer<UInt64>
  var reads = 0
  var calls = 0
  var failCopy = false
  var captured: [UInt64] = []
  func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinSyscall.TarwinCall.channelRead ? UInt32(source.count) : nil
  }
  mutating func copyUserWords(from address: UInt64, into dest: UnsafeMutableBufferPointer<UInt64>)
    -> Bool
  {
    reads += 1
    guard !failCopy, let base = source.baseAddress else { return false }
    let first = UInt64(UInt(bitPattern: base))
    guard address >= first, (address - first) / 8 <= source.count else { return false }
    let start = Int((address - first) / 8)
    guard dest.count <= source.count - start else { return false }
    for i in dest.indices { dest[i] = source[start + i] }
    return true
  }
  mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    calls += 1
    captured = Array(words)
    return CallResult(detail: 12, first: 34, second: 56)
  }
}

private struct Loopback: NativeGate {
  let isa: CallISA
  var provider: Capture
  var savedPC: UInt64 {
    switch isa {
    case .aarch64: 0x1004
    case .x64: 0x1002
    case .rv64: 0x1000
    }
  }
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    let start = UInt64(UInt(bitPattern: provider.source.baseAddress))
    let end = start + UInt64(provider.source.count) * 8
    var privateScratch = Array(repeating: UInt64.max, count: 32)
    let result = privateScratch.withUnsafeMutableBufferPointer { storage in
      dispatchCall(
        isa: isa, savedPC: savedPC, libraryCode: 0x1000..<0x1010, userRange: start..<end,
        number: number, registers: registers, scratch: storage, provider: &provider)
    }
    switch result {
    case .returned(let result): return result
    case .terminateBadOrigin:
      XCTFail("wrong instruction address")
      return CallResult(status: .max)
    }
  }
}

final class TransportTests: XCTestCase {
  func testRoundTripUsingIndependentUserAndKernelCallTables() {
    for isa in [CallISA.aarch64, .x64, .rv64] {
      for count in 0...(isa.argumentCount + 4) {
        let values = (0..<count).map { UInt64(100 + $0) }
        values.withUnsafeBufferPointer { source in
          var gate = Loopback(isa: isa, provider: Capture(source: source))
          let r = nativeCall(LibTesseraTarwin.TarwinCall.channelRead, words: source, gate: &gate)
          XCTAssertEqual(gate.provider.captured, values)
          XCTAssertEqual(gate.provider.reads, count > isa.argumentCount ? 1 : 0)
          XCTAssertEqual(gate.provider.calls, 1)
          XCTAssertEqual([r.status, r.detail, r.first, r.second], [0, 12, 34, 56])
        }
      }
    }
  }

  func testCopyFailureAndUnregisteredNumberNeverReachHandler() {
    Array(repeating: UInt64(99), count: 8).withUnsafeBufferPointer { source in
      var gate = Loopback(isa: .x64, provider: Capture(source: source, failCopy: true))
      let fault = nativeCall(LibTesseraTarwin.TarwinCall.channelRead, words: source, gate: &gate)
      XCTAssertEqual(fault.code, 1)
      XCTAssertEqual(fault.subsystem, 1)
      XCTAssertEqual(nativeCall(0, words: source, gate: &gate).code, 10)
      XCTAssertEqual(gate.provider.reads, 1)
      XCTAssertEqual(gate.provider.calls, 0)
    }
  }

  func testPCAlwaysCheckedBeforeDispatchOrUserCopy() {
    for isa in [CallISA.aarch64, .x64, .rv64] {
      var provider = Capture(source: UnsafeBufferPointer(start: nil, count: 0))
      let scratch = UnsafeMutableBufferPointer<UInt64>(start: nil, count: 0)
      let result = dispatchCall(
        isa: isa, savedPC: 0x8001, libraryCode: 0x1000..<0x2000,
        userRange: 0..<0x10000, number: 0, registers: CallRegisters(), scratch: scratch,
        provider: &provider)
      guard case .terminateBadOrigin = result else { return XCTFail() }
      XCTAssertEqual(provider.calls, 0)
      XCTAssertEqual(provider.reads, 0)
    }
    XCTAssertNil(CallISA.aarch64.instruction(savedPC: 3))
    XCTAssertNil(CallISA.x64.instruction(savedPC: 1))
    XCTAssertEqual(CallISA.rv64.instruction(savedPC: 0x1002), 0x1002)
  }
}
