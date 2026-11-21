import LibTesseraPortRings
import LibTesseraTarwin
import Synchronization
import TarwinABI
import TarwinIPC
import XCTest

private final class Mapping {
  let raw: UnsafeMutableRawPointer
  let cells: UnsafeMutableBufferPointer<Atomic<UInt32>>
  var view: UnsafeBufferPointer<Atomic<UInt32>> { UnsafeBufferPointer(cells) }
  init(stride: UInt32 = 64) {
    let count = 1024 + 32 * Int(stride)
    raw = .allocate(byteCount: count * 4, alignment: 4096)
    cells = .init(start: raw.bindMemory(to: Atomic<UInt32>.self, capacity: count), count: count)
    for i in cells.indices { cells.initializeElement(at: i, to: Atomic(0)) }
    for (i, word) in [RingFormat.magic, 1, 64, stride].enumerated() {
      cells[i].store(word, ordering: .relaxed)
    }
  }
  deinit {
    cells.deinitialize()
    raw.deallocate()
  }
}

private final class Directory: NativePortRingDirectory {
  let memory: Mapping
  var reader: NativePortRing
  var producer: RingEndpoint
  var locked = false, selected: UInt64 = 100, signals = 0, polls = 0
  init() {
    let m = Mapping()
    reader = NativePortRing(koid: 100, fresh: m.view)!
    producer = RingEndpoint(fresh: m.view, completion: true, producer: true)!
    memory = m
  }
  func withReader(named: UInt64, _ body: (UInt64, inout NativePortRing, () -> Void) -> CallResult?)
    -> CallResult?
  {
    XCTAssertFalse(locked)
    if named == 12 { return CallResult(status: 24 | 1 << 32) }
    guard named == 9 || named == 10 else { return CallResult(status: 4 | 1 << 32) }
    locked = true
    defer { locked = false }
    polls += 1
    return body(selected, &reader, { self.signals += 1 })
  }
  func post(_ first: UInt32) -> RingStep {
    var record = RingRecord()
    for i in 0..<16 { record.words[i] = first + UInt32(i) }
    return producer.push(record)
  }
}

private struct Gate: NativeGate {
  let isa: CallISA = .aarch64
  var calls: [(UInt64, UInt64)] = []
  var step: (Int) -> CallResult = { _ in
    XCTFail("unexpected sleep")
    return CallResult(status: 25)
  }
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    XCTAssertEqual(number, TarwinCall.portEnter)
    calls.append((registers.a0, registers.a1))
    return step(calls.count)
  }
}

final class WaitTests: XCTestCase {
  func testFastReadDrainsOnlyCapacityAndPreservesEveryWord() {
    var directory = Directory()
    var gate = Gate()
    for i: UInt32 in 0..<64 {
      XCTAssertEqual(directory.post(16 * i), .transferred(notifyPeer: false))
    }
    XCTAssertEqual(directory.post(2000), .wait)
    var out = [UInt64](repeating: .max, count: 16)
    for name: UInt64 in [10, 9] {
      let result = out.withUnsafeMutableBufferPointer {
        NativePorts.wait(name, into: $0, deadline: 0, directory: &directory, gate: &gate)
      }
      XCTAssertEqual(result.status, 0)
      XCTAssertEqual(result.first, 2)
      let first = name == 10 ? 0 : 32
      XCTAssertEqual(
        out,
        (0..<16).map {
          let low = UInt64(first + 2 * $0)
          return low | (low + 1) << 32
        })
    }
    XCTAssertEqual(directory.signals, 2)
    XCTAssertTrue(gate.calls.isEmpty)
  }

  func testPollAndAbsoluteDeadlineWithSpuriousAndEarlyWakes() {
    let storage = Directory()
    var directory = storage
    var gate = Gate()
    var out = [UInt64](repeating: .max, count: 16)
    func run(_ deadline: UInt64) -> CallResult {
      out.withUnsafeMutableBufferPointer {
        NativePorts.wait(9, into: $0, deadline: deadline, directory: &directory, gate: &gate)
      }
    }
    XCTAssertEqual(run(0).code, 25)
    XCTAssertTrue(gate.calls.isEmpty)
    gate.step = { attempt in
      XCTAssertFalse(storage.locked)
      if attempt == 2 { XCTAssertEqual(storage.post(99), .transferred(notifyPeer: true)) }
      return CallResult()
    }
    XCTAssertEqual(run(85).first, 1)
    XCTAssertEqual(gate.calls.map { $0.0 }, [9, 9])
    XCTAssertEqual(gate.calls.map { $0.1 }, [85, 85])
    XCTAssertEqual(out[0], 99 | 100 << 32)
    XCTAssertEqual(out[8], .max)
    gate.step = { _ in CallResult(status: 25 | 1 << 32) }
    let timeout = run(100)
    XCTAssertEqual(timeout.code, 25)
    XCTAssertEqual(timeout.first, 0)
  }

  func testBadMappingNameRightsAndBufferDoNotAdvance() {
    let wide = Mapping(stride: 128)
    if NativePortRing(koid: 100, fresh: wide.view) != nil { XCTFail() }
    var d = Directory()
    var gate = Gate()
    var out = [UInt64](repeating: .max, count: 8)
    func run(_ name: UInt64) -> CallResult {
      out.withUnsafeMutableBufferPointer {
        NativePorts.wait(name, into: $0, deadline: .max, directory: &d, gate: &gate)
      }
    }
    XCTAssertEqual(d.post(10), .transferred(notifyPeer: false))
    XCTAssertEqual(run(8).code, 4)
    XCTAssertEqual(run(12).code, 24)
    d.selected = 111
    XCTAssertEqual(run(9).code, 2)
    d.selected = 100
    out.removeLast()
    XCTAssertEqual(run(9).code, 1)
    out.append(.max)
    XCTAssertEqual(run(9).first, 1)
    d.memory.cells[Int(RingFormat.completionProducer / 4)].store(99, ordering: .releasing)
    XCTAssertEqual(run(9).code, 23)
    d.memory.cells[Int(RingFormat.completionProducer / 4)].store(1, ordering: .releasing)
    XCTAssertEqual(run(9).code, 23)
    XCTAssertTrue(gate.calls.isEmpty)
  }
}
