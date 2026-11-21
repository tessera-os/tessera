import TRFS
import TarwinDevice
import TarwinFsWire
import TarwinIPC
import XCTest

final class FsRingSessionTests: XCTestCase {
  private let node = VolumeNode(volume: 11, node: 22), none = VolumeNode(volume: 0, node: 0)
  private func withChannel(
    _ run: (inout FsRingSession, inout RingEndpoint, inout RingEndpoint) -> Void
  ) {
    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
    defer { raw.deallocate() }
    let m = IoRingMapping(initializing: raw, count: 64, stride: 64)!
    var s = FsRingSession(
      volume: 11, epoch: 42, limit: 65, requests: m.endpoint(completion: false, producer: true)!,
      replies: m.endpoint(completion: true, producer: false)!)!
    var server = m.endpoint(completion: false, producer: false)!
    var returns = m.endpoint(completion: true, producer: true)!
    run(&s, &server, &returns)
  }
  func testFullRingDoesNotCommitAndOutputWaitsForRevocation() {
    withChannel { s, server, returns in
      func read(_ s: inout FsRingSession, _ share: UInt64) -> FsPublish {
        s.submit(
          .read, node: node, other: none, offset: 1024, input: 0, inputBytes: 0, output: share,
          outputBytes: 4096,
          resolveShare: { id in
            id == share
              ? FsShare(volume: 11, id: id, backing: id, offset: 0, length: 4096, writable: true)
              : nil
          })
      }
      for i: UInt64 in 1...64 {
        XCTAssertEqual(read(&s, i), .ring(.transferred(notifyPeer: false)))
      }
      XCTAssertEqual(read(&s, 65), .ring(.wait))
      XCTAssertEqual(s.live, 64)
      var r = RingRecord()
      for i: UInt64 in 1...64 {
        guard case .transferred = server.pop(into: &r), let req = TRFS.FsRecord(record: r) else {
          return XCTFail()
        }
        XCTAssertEqual(req.id, i)
        XCTAssertEqual(req.output, i)
        XCTAssertEqual(req.op, .read)
        XCTAssertEqual(
          returns.push(FsReply(epoch: 42, id: i, status: .ok, produced: 83)!.record()),
          .transferred(notifyPeer: false))
      }
      XCTAssertEqual(returns.push(RingRecord()), .wait)
      var wake = 0
      XCTAssertEqual(
        s.poll(signalSpace: { wake += 1 }, revoke: { _ in false }, deliver: { _, _ in XCTFail() }),
        .retiring)
      XCTAssertEqual(s.live, 64)
      XCTAssertEqual(wake, 1)
      XCTAssertEqual(read(&s, 1), .rejected)
      XCTAssertEqual(
        s.poll(
          signalSpace: { XCTFail() }, revoke: { $0.output == 1 },
          deliver: { p, c in
            XCTAssertEqual(p.output, c.id)
            XCTAssertEqual(c.produced, 83)
          }), .completed)
      XCTAssertEqual(read(&s, 65), .ring(.transferred(notifyPeer: false)))
      _ = server.pop(into: &r)
      XCTAssertEqual(TRFS.FsRecord(record: r)?.id, 65)
    }
  }
  func testStaleReplyPermanentlyStopsChannelAndDisconnectRetainsFailedGrant() {
    withChannel { s, server, returns in
      XCTAssertEqual(
        s.submit(
          .write, node: node, other: none, offset: 0, input: 5, inputBytes: 12, output: 0,
          outputBytes: 0,
          resolveShare: { id in
            id == 5
              ? FsShare(volume: 11, id: id, backing: 95, offset: 10, length: 12, writable: false)
              : nil
          }),
        .ring(.transferred(notifyPeer: false)))
      var r = RingRecord()
      _ = server.pop(into: &r)
      _ = returns.push(FsReply(epoch: 41, id: 1, status: .ok, produced: 0)!.record())
      XCTAssertEqual(
        s.poll(
          signalSpace: {},
          revoke: { _ in
            XCTFail()
            return true
          }, deliver: { _, _ in XCTFail() }), .invalidReply)
      XCTAssertEqual(
        s.poll(signalSpace: {}, revoke: { _ in false }, deliver: { _, _ in XCTFail() }),
        .disconnected)
      XCTAssertFalse(s.disconnect(revoke: { _ in false }, fail: { _ in XCTFail() }))
      XCTAssertEqual(s.live, 1)
      XCTAssertTrue(s.disconnect(revoke: { $0.input == 5 }, fail: { XCTAssertEqual($0, 1) }))
      XCTAssertEqual(s.live, 0)
    }
  }
  func testRecordCodecRejectsInvalidRangesAndReservedWords() {
    for raw: UInt16 in 1...20 {
      let op = TRFS.FsOp(rawValue: raw)!
      let p = TRFS.FsRecord(
        op: op, id: 1, node: 2, other: op == .rename || op == .link ? 3 : 0, offset: 0, input: 4,
        output: 5, inputBytes: 1, outputBytes: 1)
      XCTAssertEqual(TRFS.FsRecord(record: p.record()), p)
      var r = p.record()
      r.words[1] = 1
      XCTAssertNil(TRFS.FsRecord(record: r))
    }
    let p = TRFS.FsRecord(
      op: .read, id: 1, node: 2, other: 0, offset: .max, input: 0, output: 1, inputBytes: 0,
      outputBytes: 2)
    XCTAssertNil(TRFS.FsRecord(record: p.record()))
    XCTAssertNil(FsReply(epoch: 1, id: 1, status: .io, produced: 1))
    var r = FsReply(epoch: .max, id: .max, status: .noSpace, produced: 0)!.record()
    XCTAssertEqual(FsReply(record: r)?.status, .noSpace)
    r.words[10] = 1
    XCTAssertNil(FsReply(record: r))
  }
}
