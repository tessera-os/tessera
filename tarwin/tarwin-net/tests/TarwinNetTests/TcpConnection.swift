import TarwinNet
import XCTest

final class TcpConnectionTests: XCTestCase {
  func testActiveOpenRejectsBadAcksAndRetransmitsOnlyUnackedSuffix() {
    for v6 in [false, true] {
      let syn = tcpSegment(
        wire(
          .max, [], flags: 18, options: [2, 4, 0, 8, 4, 2, 0, 0], v6: v6, ack: 0xffff_fffe,
          window: 6))!
      let path = TcpPath(
        local: syn.destination, remote: syn.source, localPort: syn.destinationPort, remotePort: 80,
        mtu: 1500)!
      var c = TcpConnection(path: path, initialSequence: 0xffff_fffd, receiveBytes: 128)!
      var packets: [TcpSegment] = []
      func emit(_ b: [UInt8]) -> Bool {
        guard let s = tcpSegment(b) else {
          XCTFail("bad output checksum")
          return false
        }
        packets.append(s)
        return true
      }
      XCTAssertFalse(c.connect(at: 0) { _ in false })
      XCTAssertEqual(c.state, .idle)
      XCTAssertTrue(c.connect(at: 0, emit: emit))
      XCTAssertEqual(packets.last?.options.mss, UInt16(v6 ? 1440 : 1460))
      XCTAssertFalse(c.input(syn, at: 1) { _ in false })
      XCTAssertEqual(c.state, .synSent)
      let bad = tcpSegment(wire(3, [], flags: 18, v6: v6, ack: 0))!
      XCTAssertFalse(c.input(bad, at: 1) { _ in true })
      XCTAssertTrue(c.input(syn, at: 10) { _ in true })
      XCTAssertEqual(c.state, .established)
      XCTAssertFalse(c.pump(at: 10) { _ in false })
      XCTAssertTrue(c.pump(at: 10, emit: emit))
      XCTAssertEqual(packets.last?.ack, 0)
      XCTAssertEqual(c.write([0, 1, 2, 3, 4, 5, 6, 7][...], at: 11, emit: emit), 6)
      XCTAssertEqual(c.write([9][...], at: 12, emit: emit), 0)
      func input(
        _ seq: UInt32, _ ack: UInt32, _ time: UInt64, _ flags: UInt8 = 16, _ bytes: [UInt8] = []
      ) -> Bool {
        c.input(tcpSegment(wire(seq, bytes, flags: flags, v6: v6, ack: ack))!, at: time) { _ in true
        }
      }
      XCTAssertTrue(input(0, 100, 13, 16, [88]))
      XCTAssertEqual(c.readable, 0)
      XCTAssertEqual(c.unacknowledged, 6)
      XCTAssertTrue(input(0, 0, 100))
      XCTAssertEqual(c.unacknowledged, 4)
      XCTAssertTrue(c.pump(at: 1_000_000_100, emit: emit))
      XCTAssertEqual(packets.last?.sequence, 0)
      XCTAssertEqual(Array(packets.last!.payload), [2, 3, 4, 5])
      XCTAssertFalse(c.pump(at: 2, emit: emit))
      XCTAssertTrue(input(0, 4, 1_000_000_101, 17, [9, 8]))
      XCTAssertEqual(c.state, .closeWait)
      XCTAssertEqual(c.read(upTo: 5) { Array($0) == [9, 8] }, 2)
      XCTAssertTrue(c.endOfInput)
      XCTAssertTrue(c.finish(at: 1_000_000_102, emit: emit))
      XCTAssertEqual(c.state, .lastAck)
      XCTAssertTrue(input(3, 5, 1_000_000_103))
      XCTAssertEqual(c.state, .closed)
    }
  }
  func testRetryBudgetAndAbortNeverPublishAfterTerminalState() {
    let path = TcpPath(
      local: [192, 0, 2, 2], remote: [192, 0, 2, 1], localPort: 33092, remotePort: 80, mtu: 1500)!
    var c = TcpConnection(path: path, initialSequence: 4, receiveBytes: 30, retries: 1)!
    XCTAssertTrue(c.connect(at: 10) { _ in true })
    XCTAssertFalse(
      c.pump(at: 1_000_000_009) { _ in
        XCTFail()
        return false
      })
    XCTAssertTrue(c.pump(at: 1_000_000_010) { tcpSegment($0)?.sequence == 4 })
    XCTAssertFalse(
      c.pump(at: 3_000_000_010) { _ in
        XCTFail()
        return false
      })
    XCTAssertEqual(c.state, .timedOut)
    var d = TcpConnection(path: path, initialSequence: 4, receiveBytes: 30)!
    XCTAssertTrue(d.connect(at: 0) { _ in true })
    d.abort()
    XCTAssertEqual(d.state, .reset)
    XCTAssertFalse(
      d.pump(at: .max) { _ in
        XCTFail()
        return false
      })
  }
  func testZeroWindowRstChallengeAndTimeWait() {
    let path = TcpPath(
      local: [192, 0, 2, 2], remote: [192, 0, 2, 1], localPort: 33092, remotePort: 80, mtu: 1500)!
    var c = TcpConnection(path: path, initialSequence: 4, receiveBytes: 4)!
    func input(
      _ seq: UInt32, _ ack: UInt32, _ flags: UInt8, _ window: UInt16 = 64, _ now: UInt64 = 2
    ) {
      XCTAssertTrue(
        c.input(tcpSegment(wire(seq, [], flags: flags, ack: ack, window: window))!, at: now) { _ in
          true
        })
    }
    XCTAssertTrue(c.connect(at: 0) { _ in true })
    input(88, 5, 18, 0)
    XCTAssertEqual(
      c.write([][...], at: 2) { _ in
        XCTFail()
        return true
      }, 0)
    input(89, 5, 16)
    input(90, 5, 4)
    XCTAssertEqual(c.state, .established)
    XCTAssertTrue(c.pump(at: 2) { tcpSegment($0)?.ack == 89 })
    XCTAssertTrue(c.finish(at: 2) { tcpSegment($0)?.flags == 17 })
    input(89, 5, 17)
    XCTAssertEqual(c.state, .closing)
    input(90, 6, 16)
    XCTAssertEqual(c.state, .timeWait)
    input(89, 6, 17, 64, 100)
    XCTAssertTrue(c.pump(at: 120_000_000_002) { tcpSegment($0)?.ack == 90 })
    XCTAssertEqual(c.state, .timeWait)
    XCTAssertFalse(c.pump(at: 120_000_000_100) { _ in false })
    XCTAssertEqual(c.state, .closed)
  }
}
