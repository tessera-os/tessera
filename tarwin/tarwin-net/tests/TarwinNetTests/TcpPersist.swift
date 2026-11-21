import XCTest

@testable import TarwinNet

final class TcpPersistTests: XCTestCase {
  private func opened(_ window: UInt16, _ v6: Bool) -> TcpConnection {
    let syn = tcpSegment(wire(70, [], flags: 18, v6: v6, ack: UInt32.max, window: window))!
    let path = TcpPath(
      local: syn.destination, remote: syn.source, localPort: syn.destinationPort,
      remotePort: syn.sourcePort, mtu: 1500)!
    var c = TcpConnection(path: path, initialSequence: .max - 1, receiveBytes: 64, retries: 1)!
    XCTAssertTrue(c.connect(at: 0) { _ in true })
    XCTAssertTrue(c.input(syn, at: 1) { _ in true })
    XCTAssertTrue(c.pump(at: 1) { _ in true })
    return c
  }
  func testCorkExpiryAndClosedWindowDrainQueuedDataWithoutOvertaking() {
    for window: UInt16 in [0, 32] {
      var c = opened(window, false)
      c.enqueueOutput([21, 22, 23], flags: 2, at: 5)
      var sent: [UInt8] = []
      func emit(_ b: [UInt8]) -> Bool {
        sent += tcpSegment(b)!.payload
        return true
      }
      XCTAssertEqual(c.write([99][...], at: 5, emit: emit), 0)
      XCTAssertFalse(c.pump(at: 200_000_004, emit: emit))
      XCTAssertTrue(sent.isEmpty)
      let deadline: UInt64 = 200_000_005
      XCTAssertEqual(c.pump(at: deadline, emit: emit), window != 0)
      if window == 0 {
        XCTAssertTrue(c.pump(at: deadline + 1_000_000_000, emit: emit))
        XCTAssertEqual(sent, [21])
        XCTAssertTrue(
          c.input(
            tcpSegment(wire(71, [], flags: 16, ack: 0, window: 2))!, at: deadline + 1_000_000_000
          ) { _ in true })
        XCTAssertTrue(c.pump(at: deadline + 1_000_000_000, emit: emit))
      }
      XCTAssertEqual(sent, [21, 22, 23])
    }
  }
  func testOneNewBytePersistsUntilPeerOpensEvenAfterManyReplies() {
    for v6 in [false, true] {
      var c = opened(0, v6)
      var sent: [TcpSegment] = []
      func emit(_ b: [UInt8]) -> Bool {
        sent.append(tcpSegment(b)!)
        return true
      }
      func ack(_ seq: UInt32, _ window: UInt16, at now: UInt64) {
        XCTAssertTrue(
          c.input(tcpSegment(wire(71, [], flags: 16, v6: v6, ack: seq, window: window))!, at: now) {
            _ in true
          })
      }
      XCTAssertEqual(c.write([17, 18][...], at: 2, emit: emit), 1)
      XCTAssertEqual(c.write([18][...], at: 2, emit: emit), 0)
      XCTAssertTrue(sent.isEmpty)
      XCTAssertEqual(c.unacknowledged, 0)
      var when: UInt64 = 1_000_000_002
      var interval: UInt64 = 1_000_000_000
      for i in 0..<9 {
        XCTAssertFalse(c.pump(at: when - 1, emit: emit))
        // Backpressure does not spend a retry or advance the sequence.
        XCTAssertFalse(c.pump(at: when) { _ in false })
        XCTAssertEqual(c.unacknowledged, i == 0 ? 0 : 1)
        XCTAssertTrue(c.pump(at: when, emit: emit))
        XCTAssertEqual(sent.last?.sequence, .max)
        XCTAssertEqual(sent.last.map { Array($0.payload) }, [17])
        XCTAssertEqual(c.unacknowledged, 1)
        ack(.max, 0, at: when)
        XCTAssertEqual(c.state, .established)
        interval = min(interval * 2, 60_000_000_000)
        when += interval
      }
      // The reopening advertisement was lost. The next retransmission is
      // accepted by the receiver and its ACK wraps the sender's sequence.
      XCTAssertTrue(c.pump(at: when, emit: emit))
      ack(0, 10, at: when)
      XCTAssertEqual(c.unacknowledged, 0)
      XCTAssertFalse(c.pump(at: when, emit: emit))
      XCTAssertEqual(c.write([18][...], at: when, emit: emit), 1)
      XCTAssertEqual(sent.last?.sequence, 0)
      XCTAssertEqual(sent.last.map { Array($0.payload) }, [18])
    }
  }
  func testShrunkenWindowProbesOnlyOldestOutstandingByteAndResumesSuffix() {
    var c = opened(32, false)
    var sent: TcpSegment?
    func emit(_ b: [UInt8]) -> Bool {
      sent = tcpSegment(b)
      return sent != nil
    }
    func ack(_ seq: UInt32, _ window: UInt16, _ now: UInt64) {
      XCTAssertTrue(
        c.input(tcpSegment(wire(71, [], flags: 16, ack: seq, window: window))!, at: now) { _ in true
        })
    }
    XCTAssertEqual(c.write([1, 2, 3, 4][...], at: 2, emit: emit), 4)
    ack(0, 0, 3)
    XCTAssertFalse(c.pump(at: 1_000_000_002, emit: emit))
    XCTAssertTrue(c.pump(at: 1_000_000_003, emit: emit))
    XCTAssertEqual(sent?.sequence, 0)
    XCTAssertEqual(sent.map { Array($0.payload) }, [2])
    ack(1, 0, 1_000_000_004)
    XCTAssertTrue(c.pump(at: 3_000_000_003, emit: emit))
    XCTAssertEqual(sent.map { Array($0.payload) }, [3])
    ack(1, 8, 3_000_000_004)
    XCTAssertTrue(c.pump(at: 3_000_000_004, emit: emit))
    XCTAssertEqual(sent?.sequence, 1)
    XCTAssertEqual(sent.map { Array($0.payload) }, [3, 4])
    ack(3, 8, 3_000_000_005)
    XCTAssertEqual(c.unacknowledged, 0)
  }
  func testLostWindowUpdateStillDeliversExactlyOnceToAFullReceiveRing() {
    var c = opened(2, false)
    var rx = TcpReceiveWindow(next: .max, capacity: 2, sackNegotiated: false)!
    func deliver(_ bytes: [UInt8]) -> Bool {
      rx.receive(tcpSegment(bytes)!) { _ in true }
    }
    func acknowledge(_ at: UInt64) {
      let a = rx.acknowledgement
      let packet = tcpSegment(wire(71, [], flags: 16, ack: a.next, window: UInt16(a.window)))!
      XCTAssertTrue(c.input(packet, at: at) { _ in true })
    }
    XCTAssertEqual(c.write([3, 5][...], at: 2, emit: deliver), 2)
    acknowledge(3)
    XCTAssertEqual(rx.acknowledgement.window, 0)
    XCTAssertEqual(c.write([7][...], at: 3, emit: deliver), 1)
    XCTAssertTrue(c.pump(at: 1_000_000_003, emit: deliver))
    XCTAssertEqual(rx.readable, 2)
    acknowledge(1_000_000_003)
    var stream: [UInt8] = []
    func copy(_ b: ArraySlice<UInt8>) -> Bool {
      stream += b
      return true
    }
    XCTAssertEqual(rx.read(upTo: 2, copy: copy), 2)
    // Lose the window update. The probe is accepted when retransmitted.
    XCTAssertTrue(c.pump(at: 3_000_000_003, emit: deliver))
    XCTAssertEqual(rx.readable, 1)
    acknowledge(3_000_000_003)
    XCTAssertEqual(c.unacknowledged, 0)
    XCTAssertEqual(c.write([11][...], at: 3_000_000_004, emit: deliver), 1)
    XCTAssertEqual(rx.read(upTo: 2, copy: copy), 2)
    XCTAssertEqual(stream, [3, 5, 7, 11])
  }
  func testEarlyReopenAndFinPersistDoNotInventApplicationBytes() {
    var c = opened(0, false)
    var sent: TcpSegment?
    func emit(_ b: [UInt8]) -> Bool {
      sent = tcpSegment(b)
      return sent != nil
    }
    XCTAssertEqual(c.write([0xaa][...], at: 2, emit: emit), 1)
    XCTAssertTrue(
      c.input(tcpSegment(wire(71, [], flags: 16, ack: .max, window: 1))!, at: 3) { _ in true })
    XCTAssertTrue(c.pump(at: 3, emit: emit))
    XCTAssertEqual(sent.map { Array($0.payload) }, [0xaa])
    XCTAssertTrue(
      c.input(tcpSegment(wire(71, [], flags: 16, ack: 0, window: 0))!, at: 4) { _ in true })
    XCTAssertTrue(c.finish(at: 5, emit: emit))
    XCTAssertEqual(c.state, .finWait1)
    XCTAssertEqual(c.unacknowledged, 0)
    XCTAssertTrue(c.pump(at: 1_000_000_005, emit: emit))
    XCTAssertEqual(sent?.flags, 17)
    XCTAssertEqual(sent?.payload.count, 0)
    XCTAssertEqual(sent?.sequence, 0)
    XCTAssertEqual(c.unacknowledged, 1)
    XCTAssertFalse(c.pump(at: 3_000_000_005, emit: emit))
    XCTAssertEqual(c.state, .timedOut)
    XCTAssertFalse(c.pump(at: .max, emit: emit))
  }
}
