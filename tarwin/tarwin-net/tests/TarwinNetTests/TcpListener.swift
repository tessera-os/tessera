import XCTest

@testable import TarwinNet

final class TcpListenerTests: XCTestCase {
  let local: [UInt8] = [192, 0, 2, 2], peer: [UInt8] = [192, 0, 2, 1]
  func testAdmissionQuotaRetryAndDrain() {
    let port: UInt16 = 711
    guard
      case nil = TcpListener(
        serverEntitled: false, local: local, port: port, interface: 7, epoch: 9, backlog: 1,
        receiveBytes: 64)
    else { return XCTFail() }
    var l = TcpListener(
      serverEntitled: true, local: local, port: port, interface: 7, epoch: 9, backlog: 1,
      receiveBytes: 64)!
    var allocations = 0
    var transmissions = 0
    var canSend = false
    func inject(
      _ remote: UInt16, _ time: UInt64, epoch: UInt64 = 9, allowed: Bool = true, seq: UInt32 = 10,
      flags: UInt8 = 2, ack: UInt32 = 0
    ) -> String {
      let out = TcpPath(local: local, remote: peer, localPort: port, remotePort: remote, mtu: 1500)!
      let back = TcpPath(
        local: peer, remote: local, localPort: remote, remotePort: port, mtu: 1500)!
      let packet = tcpSegment(back.encode(seq, ack, flags, 4, [], []))!
      switch l.input(
        packet, path: out, interface: 7, epoch: epoch, at: time, permit: { _ in allowed },
        initial: {
          allocations += 1
          return (77, nil)
        }, canPromote: { true },
        emit: { _, _ in
          transmissions += 1
          return canSend
        })
      {
      case .ignored: return "ignored"
      case .pending: return "pending"
      case .full: return "full"
      case .established: return "established"
      }
    }
    XCTAssertEqual(inject(30, 1, epoch: 8), "ignored")
    XCTAssertEqual(inject(30, 1, allowed: false), "ignored")
    XCTAssertEqual(allocations, 0)
    XCTAssertEqual(inject(30, 1), "pending")
    XCTAssertEqual(inject(30, 2, seq: 11, flags: 16, ack: 78), "ignored")
    XCTAssertEqual(inject(31, 2), "full")
    canSend = true
    var echoed: [UInt32] = []
    func retry(_ now: UInt64) {
      l.pump(at: now) { _, b in
        echoed.append(tcpSegment(b)!.sequence)
        return true
      }
    }
    retry(3)
    retry(3)
    XCTAssertEqual(inject(30, 4), "pending")
    XCTAssertEqual(inject(30, 4, seq: 7, flags: 4), "ignored")
    retry(1_000_000_003)
    retry(2_000_000_003)
    retry(3_000_000_003)
    XCTAssertEqual(echoed, [77, 77, 77])
    XCTAssertEqual(transmissions, 1)
    XCTAssertEqual(allocations, 1)
    XCTAssertEqual(inject(30, 3_000_000_004, seq: 11, flags: 20, ack: 79), "ignored")
    XCTAssertEqual(l.pending, 1)
    XCTAssertEqual(inject(30, 3_000_000_005, seq: 11, flags: 20, ack: 78), "ignored")
    XCTAssertEqual(l.pending, 0)
    XCTAssertEqual(inject(31, 4_000_000_000), "pending")
    retry(64_000_000_000)
    XCTAssertEqual(l.pending, 0)
    l.close()
    XCTAssertEqual(inject(32, 65_000_000_000), "ignored")
  }
  func testThirdAckPromotionDataAndFinAfterPaws() {
    for v6 in [false, true] {
      let opts: [UInt8] = [2, 4, 0x04, 0x00, 4, 2, 3, 3, 3, 1, 8, 10, 0, 0, 0, 7, 0, 0, 0, 0]
      let syn = tcpSegment(wire(.max, [], flags: 2, options: opts, v6: v6))!
      let r = TcpPath(
        local: syn.destination, remote: syn.source, localPort: syn.destinationPort,
        remotePort: syn.sourcePort, mtu: 1500)!
      var l = TcpListener(
        serverEntitled: true, local: r.local, port: r.localPort, interface: 5, epoch: 1, backlog: 2,
        receiveBytes: 131070)!
      var last: TcpSegment?
      var room = true
      func feed(_ p: TcpSegment) -> TcpListenInput {
        l.input(
          p, path: r, interface: 5, epoch: 1, at: 0, permit: { _ in true }, initial: { (.max, 55) },
          canPromote: { room },
          emit: { _, b in
            last = tcpSegment(b)
            return true
          })
      }
      guard case .pending = feed(syn) else { return XCTFail() }
      XCTAssertEqual(last?.flags, 18)
      XCTAssertEqual(last?.options.timestampEcho, 7)
      XCTAssertEqual(last?.options.scale, 1)
      XCTAssertEqual(last?.window, 65535)
      func third(_ ts: UInt8, _ ack: UInt32 = 0, _ seq: UInt32 = 0) -> TcpSegment {
        tcpSegment(
          wire(
            seq, [0, 255], flags: 17, options: [1, 1, 8, 10, 0, 0, 0, ts, 0, 0, 0, 55],
            v6: v6, ack: ack, window: 2))!
      }
      guard case .ignored = feed(third(8, 1)), case .ignored = feed(third(6)),
        case .ignored = feed(third(8, 0, 1))
      else { return XCTFail() }
      room = false
      guard case .full = feed(third(8)) else { return XCTFail() }
      XCTAssertEqual(l.pending, 1)
      room = true
      guard case .established(var c) = feed(third(8)) else { return XCTFail() }
      XCTAssertEqual(l.pending, 0)
      XCTAssertEqual(c.state, .closeWait)
      XCTAssertEqual(c.read(upTo: 9) { Array($0) == [0, 255] }, 2)
      XCTAssertTrue(c.endOfInput)
      XCTAssertEqual(
        c.write(Array(repeating: 17, count: 32)[...], at: 1) { b in
          last = tcpSegment(b)
          return true
        }, 16)
      XCTAssertEqual(last?.options.timestampEcho, 8)
      XCTAssertEqual(last?.ack, 3)
    }
  }
}
