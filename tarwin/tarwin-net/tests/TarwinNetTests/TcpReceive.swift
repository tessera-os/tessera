import XCTest

@testable import TarwinNet

private func be(_ value: UInt32, _ n: Int) -> [UInt8] {
  (0..<n).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
private func checksum(_ data: [UInt8]) -> [UInt8] {
  var n = 0
  for (i, b) in data.enumerated() { n += Int(b) << (i % 2 == 0 ? 8 : 0) }
  while n > 0xffff { n = (n >> 16) + (n & 0xffff) }
  return be(UInt32(65535 - n), 2)
}
func wire(
  _ seq: UInt32, _ data: [UInt8], flags: UInt8 = 16, options: [UInt8] = [], v6: Bool = false,
  ack: UInt32 = 5, window: UInt16 = 64
) -> [UInt8] {
  let head = 20 + options.count
  precondition(head % 4 == 0)
  var tcp: [UInt8] =
    [0, 80, 0x81, 0x44] + be(seq, 4) + be(ack, 4) + [UInt8(head / 4) << 4, flags]
    + be(UInt32(window), 2) + [0, 0, 0, 0]
    + options + data
  let addr: [UInt8] =
    v6
    ? [0xfd] + Array(repeating: 0, count: 14) + [1, 0xfd] + Array(repeating: 0, count: 14) + [2]
    : [192, 0, 2, 1, 192, 0, 2, 2]
  let n = UInt32(tcp.count)
  let pseudo = addr + (v6 ? be(n, 4) + [0, 0, 0, 6] : [0, 6] + be(n, 2))
  tcp.replaceSubrange(16..<18, with: checksum(pseudo + tcp))
  if v6 { return [0x60, 0, 0, 0] + be(n, 2) + [6, 64] + addr + tcp }
  var ip: [UInt8] = [0x45, 0] + be(n + 20, 2) + [0, 0, 0x40, 0, 64, 6, 0, 0] + addr
  ip.replaceSubrange(10..<12, with: checksum(ip))
  return ip + tcp
}
final class TcpReceiveTests: XCTestCase {
  func testTcpEnvelopeAndOptionValidation() {
    let options: [UInt8] = [
      2, 4, 5, 0xb4, 3, 3, 18, 4, 2, 1, 1, 1, 8, 10, 0, 0, 0, 3, 0, 0, 0, 5, 0, 0,
    ]
    for v6 in [true, false] {
      var raw = wire(0xdead_beef, [0, 1, 2], flags: 2, options: options, v6: v6)
      let p = tcpSegment(raw + [0xff])!
      XCTAssertEqual(p.sequence, 0xdead_beef)
      XCTAssertEqual(Array(p.payload), [0, 1, 2])
      XCTAssertEqual(p.options.mss, 1460)
      XCTAssertTrue(p.options.sackPermitted)
      XCTAssertEqual(p.options.scale, 14)
      XCTAssertEqual(p.options.timestampEcho, 5)
      for i in 0..<raw.count { XCTAssertNil(tcpSegment(Array(raw.prefix(i)))) }
      raw[raw.count - 1] ^= 1
      XCTAssertNil(tcpSegment(raw))
    }
    for opt: [UInt8] in [
      [0, 1, 0, 0], [9, 0, 0, 0], [3, 4, 1, 1], [8, 10, 1, 1], [5, 2, 0, 0],
      [5, 10, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0],
    ] {
      XCTAssertNil(tcpSegment(wire(0, [], options: opt)))
    }
    let sack: [UInt8] = [5, 10, 0xff, 0xff, 0xff, 0xfe, 0, 0, 0, 2, 1, 1]
    XCTAssertEqual(
      tcpSegment(wire(1, [], options: sack))?.options.sacks,
      [SackBlock(left: 0xffff_fffe, right: 2)!])
  }
  func testWrapFirstCopyWinsAndFinAtGap() {
    let base: UInt32 = 0xffff_fffc
    var w = TcpReceiveWindow(next: base, capacity: 12, maxGaps: 2, sackNegotiated: true)!
    func receive(_ offset: Int, _ values: [UInt8], fin: Bool = false, allow: Bool = true) {
      let p = tcpSegment(
        wire(base &+ UInt32(truncatingIfNeeded: offset), values, flags: fin ? 17 : 16))!
      XCTAssertEqual(w.receive(p) { _ in allow }, allow)
    }
    receive(5, [5, 6])
    receive(9, [9], fin: true)
    receive(3, [3])  // out of gap slots
    XCTAssertEqual(w.acknowledgement.next, base)
    XCTAssertEqual(w.acknowledgement.sackOption(available: 10), [5, 10, 0, 0, 0, 5, 0, 0, 0, 6])
    receive(1, Array(repeating: 88, count: 10), allow: false)
    receive(7, [7, 8])
    receive(-2, [7, 7, 0, 1, 2, 3, 4, 99, 99])
    XCTAssertTrue(w.acknowledgement.finished)
    XCTAssertEqual(w.acknowledgement.next, 7)
    XCTAssertFalse(w.atEnd)
    var bytes: [UInt8] = []
    XCTAssertEqual(w.read(upTo: 12) { _ in false }, 0)
    XCTAssertEqual(
      w.read(upTo: 12) {
        bytes += Array($0)
        return true
      }, 10)
    XCTAssertEqual(bytes, Array(0...9))
    XCTAssertTrue(w.atEnd)
    XCTAssertEqual(w.acknowledgement.next, 7)
  }
  func testBoundedWindowClippingPartialReadReopensRightEdge() {
    var w = TcpReceiveWindow(next: 40, capacity: 4, sackNegotiated: false)!
    func add(_ n: UInt32, _ b: [UInt8], _ flags: UInt8 = 16) {
      _ = w.receive(tcpSegment(wire(n, b, flags: flags))!) { _ in true }
    }
    add(40, [1, 2, 3, 4, 5], 17)
    XCTAssertFalse(w.acknowledgement.finished)
    XCTAssertEqual(w.acknowledgement.window, 0)
    XCTAssertEqual(w.read(upTo: 3) { _ in true }, 3)
    add(44, [5, 6, 7])
    var calls = 0
    XCTAssertEqual(
      w.read(upTo: 10) { _ in
        calls += 1
        return calls == 1
      }, 1)
    XCTAssertEqual(w.readable, 3)
    add(47, [], 17)
    XCTAssertEqual(w.acknowledgement.next, 48)
    XCTAssertEqual(w.read(upTo: 9) { Array($0) == [5, 6, 7] }, 3)
    XCTAssertTrue(w.atEnd)
  }
  func testOverlappingWindowMatchesIndependentFirstArrivalOracle() {
    let origin: UInt32 = 0xffff_ff8a
    var w = TcpReceiveWindow(next: origin, capacity: 24, maxGaps: 24, sackNegotiated: true)!
    var model = [UInt8?](repeating: nil, count: 24)
    var total = 0
    var seed: UInt32 = 27
    func random(_ n: Int) -> Int {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return Int(seed >> 12) % n
    }
    for _ in 0..<1000 {
      let offset = random(38) - 8
      let data = (0..<random(12)).map { _ in UInt8(random(256)) }
      _ = w.receive(tcpSegment(wire(origin &+ UInt32(truncatingIfNeeded: total + offset), data))!) {
        _ in true
      }
      for (i, b) in data.enumerated() {
        let k = offset + i
        if model.indices.contains(k), model[k] == nil { model[k] = b }
      }
      let count = model.firstIndex(of: nil) ?? model.count
      XCTAssertEqual(w.readable, count)
      XCTAssertEqual(w.acknowledgement.next, origin &+ UInt32(total + count))
      let n = min(count, random(6))
      var read: [UInt8] = []
      XCTAssertEqual(
        w.read(upTo: n) {
          read += Array($0)
          return true
        }, n)
      XCTAssertEqual(read, model.prefix(n).compactMap { $0 })
      model.removeFirst(n)
      model.append(contentsOf: repeatElement(nil, count: n))
      total += n
    }
  }
}
