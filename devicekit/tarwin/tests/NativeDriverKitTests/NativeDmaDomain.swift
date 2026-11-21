import LibTesseraTarwin
import NativeDriverKit
import TarwinABI
import XCTest

private struct Gate: NativeGate {
  let isa: CallISA
  var number: UInt64 = 0, words = CallRegisters(), result = CallResult()
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    self.number = number
    words = registers
    return result
  }
}

final class NativeDmaDomainTests: XCTestCase {
  func testAcquireAndMapWithDirectionalRegisters() throws {
    for isa: CallISA in [.aarch64, .rv64, .x64] {
      var gate = Gate(isa: isa)
      gate.result = CallResult(first: 44)
      let d = try NativeDmaDomain.acquire(slot: 11, gate: &gate)
      XCTAssertEqual(gate.number, TarwinCall.deviceSlotIommuDomain)
      XCTAssertEqual(gate.words.a0, 11)
      for (direction, bits) in [
        (DmaDirection.toDevice, UInt64(1)), (.fromDevice, 2), (.bidirectional, 3),
      ] {
        gate.result = CallResult(first: 71, second: 0)
        let b = try d.map(memory: 52, offset: 8192, bytes: 4096, direction: direction, gate: &gate)
        XCTAssertEqual(gate.number, TarwinCall.dmaBufferCreate)
        XCTAssertEqual((0..<6).map { gate.words[$0] }, [44, 52, 8192, 4096, bits, 0])
        XCTAssertEqual(b.handle, 71)
        XCTAssertEqual(b.iova, 0)
        XCTAssertEqual(b.length, 4096)
        XCTAssertEqual(b.owner, .cpu)
        XCTAssertEqual(b.direction, direction)
      }
      gate.result = CallResult(status: 0x5_0000_0004, detail: 83, first: 1, second: 4096)
      XCTAssertThrowsError(
        try d.map(memory: 52, offset: 0, bytes: 4096, direction: .fromDevice, gate: &gate)
      ) {
        XCTAssertEqual(($0 as? NativeDmaError)?.status, 0x5_0000_0004)
        XCTAssertEqual(($0 as? NativeDmaError)?.detail, 83)
      }
      XCTAssertThrowsError(try NativeDmaDomain.acquire(slot: 11, gate: &gate))
    }
  }
}
