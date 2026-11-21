import TarwinNet
import XCTest

final class SimultaneousOpenTests: XCTestCase {
  func testCrossedSynsWithWrapOptionsAndBidirectionalData() throws {
    for v6 in [false, true] {
      let sample = try XCTUnwrap(tcpSegment(wire(0, [], v6: v6)))
      let path = TcpPath(
        local: sample.destination, remote: sample.source, localPort: 32001,
        remotePort: 32002, mtu: 1500)!
      let reverse = TcpPath(
        local: path.remote, remote: path.local, localPort: path.remotePort,
        remotePort: path.localPort, mtu: 1500)!
      var a = TcpConnection(
        path: path, initialSequence: .max, receiveBytes: 131_070, timestampOffset: 300)!
      var b = TcpConnection(
        path: reverse, initialSequence: 111, receiveBytes: 8192, timestampOffset: 901)!
      var ab: TcpSegment?
      var ba: TcpSegment?
      func sendA(_ packet: [UInt8]) -> Bool {
        ab = tcpSegment(packet)
        return ab != nil
      }
      func sendB(_ packet: [UInt8]) -> Bool {
        ba = tcpSegment(packet)
        return ba != nil
      }
      XCTAssertTrue(a.connect(at: 0, emit: sendA))
      XCTAssertTrue(b.connect(at: 0, emit: sendB))
      let aSyn = try XCTUnwrap(ab)
      let bSyn = try XCTUnwrap(ba)
      XCTAssertTrue(a.input(bSyn, at: 1) { _ in true })
      XCTAssertTrue(b.input(aSyn, at: 1) { _ in true })
      XCTAssertEqual(a.state, .synReceived)
      XCTAssertEqual(b.state, .synReceived)
      XCTAssertEqual(b.write([1][...], at: 1, emit: sendB), 0)
      XCTAssertFalse(a.pump(at: 2) { _ in false })
      XCTAssertTrue(a.pump(at: 2, emit: sendA))
      XCTAssertTrue(b.pump(at: 2, emit: sendB))
      let aReply = try XCTUnwrap(ab)
      let bReply = try XCTUnwrap(ba)
      XCTAssertEqual(aReply.sequence, aSyn.sequence)
      XCTAssertEqual(aReply.flags, 18)
      XCTAssertEqual(bReply.ack, 0)
      XCTAssertEqual(aReply.window, 65535)
      XCTAssertEqual(aReply.options.scale, 1)
      XCTAssertEqual(aReply.options.timestampEcho, bSyn.options.timestamp)
      XCTAssertTrue(bReply.options.sackPermitted)
      XCTAssertEqual(a.unacknowledged, 1)
      XCTAssertTrue(a.input(bReply, at: 3) { _ in true })
      XCTAssertTrue(b.input(aReply, at: 3) { _ in true })
      XCTAssertEqual(a.state, .established)
      XCTAssertEqual(b.state, .established)
      XCTAssertEqual(a.unacknowledged, 0)
      XCTAssertEqual(b.unacknowledged, 0)
      XCTAssertEqual(a.write([0, 255][...], at: 4, emit: sendA), 2)
      XCTAssertTrue(b.input(try XCTUnwrap(ab), at: 5) { _ in true })
      XCTAssertEqual(b.read(upTo: 4) { Array($0) == [0, 255] }, 2)
      XCTAssertEqual(b.write([127][...], at: 6, emit: sendB), 1)
      XCTAssertTrue(a.input(try XCTUnwrap(ba), at: 7) { _ in true })
      XCTAssertEqual(a.read(upTo: 4) { Array($0) == [127] }, 1)
      XCTAssertEqual(a.unacknowledged, 0)
      XCTAssertTrue(a.pump(at: 8, emit: sendA))
      XCTAssertTrue(b.input(try XCTUnwrap(ab), at: 9) { _ in true })
      XCTAssertEqual(b.unacknowledged, 0)
    }
  }

  func testSynAckRetryAndDataOnFinalAck() {
    let path = TcpPath(
      local: [192, 0, 2, 2], remote: [192, 0, 2, 1],
      localPort: 33092, remotePort: 80, mtu: 1500)!
    var c = TcpConnection(path: path, initialSequence: 4, receiveBytes: 32, retries: 1)!
    let syn = tcpSegment(wire(.max, [], flags: 2, ack: 19))!
    let final = tcpSegment(wire(0, [1, 2], flags: 17))!
    XCTAssertTrue(c.connect(at: 0) { _ in true })
    XCTAssertTrue(c.input(syn, at: 1) { _ in true })
    XCTAssertFalse(c.input(final, at: 2) { _ in true })
    func reply(_ packet: [UInt8]) -> Bool {
      guard let p = tcpSegment(packet) else { return false }
      return p.sequence == 4 && p.ack == 0 && p.flags == 18 && p.options.scale == nil
        && p.options.timestamp == nil && !p.options.sackPermitted
    }
    XCTAssertTrue(c.pump(at: 2, emit: reply))
    XCTAssertTrue(c.input(syn, at: 3) { _ in true })
    XCTAssertFalse(c.input(tcpSegment(wire(1, [], flags: 4))!, at: 4) { _ in true })
    XCTAssertFalse(c.input(tcpSegment(wire(0, [], ack: 6))!, at: 4) { _ in true })
    XCTAssertEqual(c.state, .synReceived)
    XCTAssertFalse(c.pump(at: 1_000_000_001, emit: reply))
    XCTAssertTrue(c.pump(at: 1_000_000_002, emit: reply))
    XCTAssertEqual(c.unacknowledged, 1)
    XCTAssertTrue(c.input(final, at: 1_000_000_003) { _ in true })
    XCTAssertEqual(c.state, .closeWait)
    XCTAssertEqual(c.unacknowledged, 0)
    XCTAssertEqual(c.read(upTo: 10) { Array($0) == [1, 2] }, 2)
    XCTAssertTrue(c.endOfInput)
  }
}
