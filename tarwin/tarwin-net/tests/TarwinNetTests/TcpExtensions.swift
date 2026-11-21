import TarwinNet
import XCTest

private func ts(_ stamp: UInt32, echo: UInt32 = 0) -> [UInt8] {
  var bytes: [UInt8] = [1, 1, 8, 10]
  for v in [stamp, echo] {
    for n in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: v >> n)) }
  }
  return bytes
}

final class TcpExtensionTests: XCTestCase {
  private let path = TcpPath(
    local: [192, 0, 2, 2], remote: [192, 0, 2, 1],
    localPort: 33092, remotePort: 80, mtu: 1500)!

  func testWindowScaleIsDirectionalAndBothSynWindowsAreUnscaled() {
    for negotiated in [false, true] {
      var c = TcpConnection(path: path, initialSequence: 4, receiveBytes: 131_070)!
      XCTAssertTrue(
        c.connect(at: 0) { ip in
          let p = tcpSegment(ip)!
          return p.window == 65535 && p.options.scale == 1
        })
      let opts: [UInt8] = negotiated ? [3, 3, 3, 0] : []
      let syn = tcpSegment(wire(50, [], flags: 18, options: opts, window: 2))!
      XCTAssertTrue(c.input(syn, at: 1) { _ in true })
      let data = Array(repeating: UInt8(77), count: 24)[...]
      XCTAssertEqual(
        c.write(data, at: 2) { ip in
          let p = tcpSegment(ip)!
          return p.window == 65535 && p.options.scale == nil
        }, 2)
      XCTAssertTrue(
        c.input(tcpSegment(wire(51, [42, 0], ack: 7, window: 3))!, at: 3) { _ in true })
      XCTAssertEqual(
        c.write(data, at: 4) { ip in tcpSegment(ip)?.window == (negotiated ? 65534 : 65533) },
        negotiated ? 24 : 3)
    }
  }

  func testTimestampNegotiationWrapDelayedAckPawsAndRst() {
    var c = TcpConnection(path: path, initialSequence: 4, receiveBytes: 96, timestampOffset: .max)!
    var output: TcpSegment?
    func emit(_ bytes: [UInt8]) -> Bool {
      output = tcpSegment(bytes)
      return output != nil
    }
    func input(
      _ seq: UInt32, _ bytes: [UInt8], _ stamp: UInt32?, _ time: UInt64,
      flags: UInt8 = 16, ack: UInt32 = 5
    ) {
      XCTAssertTrue(
        c.input(
          tcpSegment(
            wire(
              seq, bytes, flags: flags,
              options: stamp.map { ts($0, echo: .max) } ?? [], ack: ack))!, at: time
        ) { _ in true })
    }
    XCTAssertTrue(c.connect(at: 0, emit: emit))
    XCTAssertEqual(output?.options.timestamp, .max)
    XCTAssertEqual(output?.options.timestampEcho, 0)
    input(30, [], .max - 1, 1, flags: 18)
    XCTAssertTrue(c.pump(at: 1_000_000, emit: emit))
    XCTAssertEqual(output?.options.timestamp, 0)
    XCTAssertEqual(output?.options.timestampEcho, .max - 1)
    input(33, [3], 5, 1_000_001)
    XCTAssertTrue(c.pump(at: 1_000_002, emit: emit))
    XCTAssertEqual(output?.options.timestampEcho, .max - 1, "do not echo an out-of-order segment")
    input(31, [1], 1, 1_000_003)
    XCTAssertFalse(c.pump(at: 1_000_003) { _ in false })
    input(32, [2], 2, 1_000_004)
    XCTAssertTrue(c.pump(at: 1_000_004, emit: emit))
    XCTAssertEqual(output?.ack, 34)
    XCTAssertEqual(output?.options.timestampEcho, 1, "preserve earliest unacknowledged segment")
    input(34, [4], 0, 1_000_005)
    XCTAssertTrue(c.pump(at: 1_000_005, emit: emit))
    XCTAssertEqual(output?.ack, 34)
    XCTAssertEqual(c.readable, 3)
    input(34, [4], nil, 1_000_006)
    XCTAssertFalse(c.pump(at: 1_000_006, emit: emit), "missing timestamps are silently discarded")
    XCTAssertEqual(c.readable, 3)
    let later: UInt64 = 2_073_600_000_000_000 + 1_000_004
    input(34, [4], 0, later)
    XCTAssertTrue(c.pump(at: later, emit: emit))
    XCTAssertEqual(output?.ack, 35)
    XCTAssertEqual(output?.options.timestampEcho, 0)
    input(35, [], nil, later, flags: 4)
    XCTAssertEqual(c.state, .reset)
  }

  func testOptionSpaceAndEchoAfterRetransmission() {
    let p = TcpPath(
      local: path.local, remote: path.remote, localPort: path.localPort, remotePort: 80, mtu: 68)!
    var c = TcpConnection(path: p, initialSequence: 4, receiveBytes: 64, timestampOffset: 20)!
    XCTAssertTrue(c.connect(at: 0) { $0.count <= 68 })
    let syn = tcpSegment(wire(100, [], flags: 18, options: [2, 4, 0, 26] + ts(33, echo: 20)))!
    XCTAssertTrue(c.input(syn, at: 10) { _ in true })
    XCTAssertEqual(
      c.write(Array(repeating: 1, count: 30)[...], at: 20) { ip in
        ip.count == 66 && tcpSegment(ip)?.options.timestampEcho == 33
      }, 14)
    XCTAssertTrue(
      c.pump(at: 1_000_000_020) { ip in
        tcpSegment(ip)?.options.timestamp == 1020 && ip.count == 66
      })
    let ack = tcpSegment(wire(101, [], options: ts(34, echo: 1020), ack: 19))!
    XCTAssertTrue(c.input(ack, at: 1_010_000_020) { _ in true })
    XCTAssertEqual(c.write([0][...], at: 1_010_000_020) { _ in true }, 1)
    XCTAssertTrue(
      c.pump(at: 2_010_000_020) { _ in true }, "echo of the retry provides an unambiguous RTT")
  }
}
