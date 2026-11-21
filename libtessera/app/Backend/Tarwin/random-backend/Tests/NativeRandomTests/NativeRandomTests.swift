import LibTesseraRandom
import LibTesseraTarwin
import TarwinABI
import TarwinRandomCalls
import TarwinRandomCore
import XCTest

private struct Context: KernelRandomCallContext {
  var userRange = UInt64(1)..<UInt64.max
  var epoch: RandomEpoch? = .physical
  var copyAllowed = true
  var seeds: UInt8 = 0
  var destination: UnsafeMutableRawBufferPointer?
  mutating func freshSeed(into bytes: UnsafeMutableRawBufferPointer) -> RandomEpoch? {
    seeds += 1
    for i in bytes.indices { bytes[i] = seeds }
    return epoch
  }
  func copyOut(to address: UInt64, from bytes: UnsafeRawBufferPointer) -> Bool {
    guard copyAllowed, let destination, destination.count == bytes.count,
      UInt(bitPattern: destination.baseAddress) == address
    else { return false }
    destination.copyMemory(from: bytes)
    return true
  }
}
private struct Gate: NativeGate {
  let isa = CallISA.aarch64
  var calls = RandomCalls(context: Context())
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    var address = registers.a0
    calls.context.destination = .init(
      start: UnsafeMutableRawPointer(bitPattern: UInt(address)), count: 32)
    defer { calls.context.destination = nil }
    return withUnsafePointer(to: &address) {
      calls.invoke(number: number, words: .init(start: $0, count: 1))
    }
  }
}

final class NativeRandomTests: XCTestCase {
  func testThreadFastPathAndRestore() {
    let a = RandomEpoch.virtualMachine(low: 1, high: 2)
    let b = RandomEpoch.virtualMachine(low: 1, high: 3)
    var n = NativeRandom()
    var g = Gate()
    var buf = [UInt8](repeating: 0, count: 71)
    g.calls.context.epoch = a
    buf.withUnsafeMutableBytes { dst in
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { a }).code, 0)
      let first = Array(dst)
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { a }).code, 0)
      XCTAssertNotEqual(Array(dst), first)
      XCTAssertEqual(g.calls.context.seeds, 1)
      let previous = Array(dst)
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { nil }).code, 23)
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { b }).code, 23)
      XCTAssertEqual(Array(dst), previous)
      g.calls.context.epoch = b
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { b }).code, 0)
      XCTAssertEqual(g.calls.context.seeds, 3)
      var reads = 0
      XCTAssertEqual(
        n.fill(
          dst, gate: &g,
          epoch: {
            reads += 1
            return reads == 1 ? b : a
          }
        ).code, 23)
      XCTAssertEqual(Array(dst), Array(repeating: 0, count: dst.count))
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { b }).code, 0)
      XCTAssertEqual(g.calls.context.seeds, 4)
    }
  }
  func testProviderCannotWriteUnvalidatedOutputOrPublishFailedSeed() {
    var calls = RandomCalls(context: Context())
    calls.context.userRange = 0x1000..<0x2000
    for address: UInt64 in [0, 0x0fff, 0x1fe1, .max] {
      [address].withUnsafeBufferPointer {
        XCTAssertEqual(calls.invoke(number: TarwinCall.randomFill, words: $0).code, 1)
      }
    }
    XCTAssertEqual(calls.context.seeds, 0)
    var g = Gate()
    var n = NativeRandom()
    var data = [UInt8](repeating: 42, count: 32)
    data.withUnsafeMutableBytes { dst in
      g.calls.context.epoch = nil
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { .physical }).code, 23)
      g.calls.context.epoch = .physical
      g.calls.context.copyAllowed = false
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { .physical }).code, 1)
      XCTAssertEqual(Array(dst), [UInt8](repeating: 42, count: 32))
      g.calls.context.copyAllowed = true
      XCTAssertEqual(n.fill(dst, gate: &g, epoch: { .physical }).code, 0)
    }
  }
}
