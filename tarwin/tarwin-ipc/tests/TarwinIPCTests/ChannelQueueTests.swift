import TarwinIPCChannels
import TarwinObject
import XCTest

private final class Pair {
  let lengths = UnsafeMutableBufferPointer<ChannelSize>.allocate(capacity: 2)
  let payload = UnsafeMutableRawBufferPointer.allocate(byteCount: 8, alignment: 8)
  let grants = UnsafeMutableBufferPointer<ObjectGrant>.allocate(capacity: 128)
  let sendCells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 8)
  let receiveCells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 2)
  let header = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  var src: HandleTable
  var dst: HandleTable
  var queue: ChannelQueue
  init() {
    lengths.initialize(repeating: ChannelSize())
    src = HandleTable(storage: sendCells, salt: 2)!
    dst = HandleTable(storage: receiveCells, salt: 3)!
    queue = ChannelQueue(lengths: lengths, bytes: payload, grants: grants)!
    header.initialize(
      to: ObjectHeader(source: KoidSource(), ownerJob: 1, kind: TarwinKind.port, maximumRights: 7)!)
  }
  deinit {
    queue.closeReceiver { _ in XCTFail("caller still live") }
    src.drain { _ in XCTFail() }
    dst.drain { _ in XCTFail() }
    XCTAssertEqual(header.pointee.release(), .destroy)
    header.deinitialize(count: 1)
    header.deallocate()
    sendCells.deinitialize()
    sendCells.deallocate()
    receiveCells.deinitialize()
    receiveCells.deallocate()
    grants.deallocate()
    lengths.deinitialize()
    lengths.deallocate()
    payload.deallocate()
  }
  func name(_ rights: UInt64 = 7) -> UInt64 {
    guard case .installed(let n) = src.install(header, rights: rights) else {
      XCTFail()
      return 0
    }
    return n
  }
  func write(_ bytes: [UInt8], _ names: [UInt64] = []) -> ChannelStatus {
    bytes.withUnsafeBytes { b in
      names.withUnsafeBufferPointer { n in
        queue.write(b, names: n, from: &src) { _ in XCTFail() }
      }
    }
  }
  func read(_ byteCapacity: Int, _ nameCapacity: Int) -> (ChannelStatus, [UInt8], [UInt64]) {
    var data = [UInt8](repeating: 0xcc, count: byteCapacity)
    var names = [UInt64](repeating: 0, count: nameCapacity)
    var size = ChannelSize()
    let status = data.withUnsafeMutableBytes { b in
      names.withUnsafeMutableBufferPointer { n in
        queue.read(into: b, names: n, to: &dst, size: &size)
      }
    }
    if status != .ok {
      XCTAssertTrue(data.allSatisfy { $0 == 0xcc })
      XCTAssertTrue(names.allSatisfy { $0 == 0 })
    }
    return (status, Array(data.prefix(size.bytes)), Array(names.prefix(size.handles)))
  }
}

final class ChannelQueueTests: XCTestCase {
  func testPairPublishesReadinessOnTheCorrectEnd() {
    let pair = Pair()
    let heads = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 2)
    let ids = KoidSource()
    for i in 0..<2 {
      (heads + i).initialize(
        to: ObjectHeader(source: ids, ownerJob: 1, kind: TarwinKind.channel, maximumRights: 7)!)
    }
    let lengths = UnsafeMutableBufferPointer<ChannelSize>.allocate(capacity: 2)
    lengths.initialize(repeating: ChannelSize())
    let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 8)
    let grants = UnsafeMutableBufferPointer<ObjectGrant>.allocate(capacity: 128)
    defer {
      for i in 0..<2 { XCTAssertEqual((heads + i).pointee.release(), .destroy) }
      heads.deinitialize(count: 2)
      heads.deallocate()
      lengths.deinitialize()
      lengths.deallocate()
      bytes.deallocate()
      grants.deallocate()
    }
    func queue(_ i: Int) -> ChannelQueue {
      ChannelQueue(
        lengths: .init(start: lengths.baseAddress! + i, count: 1),
        bytes: .init(start: bytes.baseAddress! + i * 8, count: 8),
        grants: .init(start: grants.baseAddress! + i * 64, count: 64))!
    }
    var q = ChannelPair(a: heads, b: heads + 1, toA: queue(0), toB: queue(1))!
    XCTAssertEqual(heads.pointee.signals, 2)
    let a = pair.name(6)
    XCTAssertEqual(
      [a].withUnsafeBufferPointer { names in
        [UInt8(21)].withUnsafeBytes {
          q.send(from: .a, $0, names: names, table: &pair.src) { _ in XCTFail() }
        }
      }, .ok)
    XCTAssertEqual(heads.pointee.signals, 0)
    XCTAssertEqual((heads + 1).pointee.signals, 3)
    XCTAssertEqual(q.peek(at: .b)?.bytes, 1)
    XCTAssertNil(q.peek(at: .a))
    q.close(.a) { _ in XCTFail() }
    XCTAssertEqual((heads + 1).pointee.signals, 5)
    var size = ChannelSize()
    var name: UInt64 = 0
    var result: UInt8 = 0
    let status = withUnsafeMutableBytes(of: &result) { data in
      withUnsafeMutablePointer(to: &name) {
        q.receive(
          at: .b, into: data, names: .init(start: $0, count: 1), table: &pair.dst, size: &size)
      }
    }
    XCTAssertEqual(status, .ok)
    XCTAssertEqual(result, 21)
    XCTAssertEqual((heads + 1).pointee.signals, 4)
    XCTAssertTrue(pair.dst.close(name) { _ in XCTFail() })
    q.close(.b) { _ in XCTFail() }
  }
  func testFifoWrapBackpressureAndPeerDeath() {
    let p = Pair()
    XCTAssertEqual(p.read(8, 0).0, .shouldWait)
    XCTAssertEqual(p.write([1, 2, 3, 4, 5, 6]), .ok)
    XCTAssertEqual(p.read(8, 0).1, [1, 2, 3, 4, 5, 6])
    XCTAssertEqual(p.write([7, 8, 9, 10, 11]), .ok)
    XCTAssertEqual(p.write([12, 13, 14]), .ok)
    XCTAssertFalse(p.queue.writable)
    let lost = p.name()
    XCTAssertEqual(p.write([15], [lost]), .shouldWait)
    XCTAssertFalse(p.src.close(lost) { _ in XCTFail() })
    XCTAssertEqual(p.queue.nextSize?.bytes, 5)
    XCTAssertEqual(p.read(4, 0).0, .bufferTooSmall(bytes: 5, handles: 0))
    XCTAssertEqual(p.read(5, 0).1, [7, 8, 9, 10, 11])
    XCTAssertTrue(p.queue.writable)
    p.queue.closeSender()
    XCTAssertFalse(p.queue.writable)
    XCTAssertEqual(p.read(8, 0).1, [12, 13, 14])
    XCTAssertEqual(p.read(8, 0).0, .peerClosed)
    XCTAssertFalse(p.queue.readable)
  }

  func testReceiverQuotaRetainsWholeMessageAndExactGrants() {
    let p = Pair()
    guard case .installed(let occupied) = p.dst.install(p.header, rights: 0) else {
      return XCTFail()
    }
    let a = p.name(2)
    let b = p.name(6)
    XCTAssertEqual(p.write([23], [a, b]), .ok)
    XCTAssertFalse(p.src.close(a) { _ in XCTFail() })
    XCTAssertEqual(p.read(1, 1).0, .bufferTooSmall(bytes: 1, handles: 2))
    XCTAssertEqual(p.read(1, 2).0, .handleLimit)
    XCTAssertEqual(p.queue.nextSize?.handles, 2)
    XCTAssertTrue(p.dst.close(occupied) { _ in XCTFail() })
    let (status, bytes, names) = p.read(1, 2)
    XCTAssertEqual(status, .ok)
    XCTAssertEqual(bytes, [23])
    XCTAssertEqual(names.count, 2)
    for (n, rights) in zip(names, [UInt64(2), 6]) {
      guard case .found(let g) = p.dst.reader.pinWithinEpoch(n, kind: TarwinKind.port, need: rights)
      else { return XCTFail() }
      XCTAssertEqual(g.rights, rights)
      g.drop { _ in XCTFail() }
    }
  }

  func testRightsPreflightPrecedesMoveEvenWhenPeerIsGone() {
    let p = Pair()
    let a = p.name()
    let b = p.name(4)
    XCTAssertEqual(p.write([], [a, a]), .invalidHandle)
    XCTAssertEqual(p.write([], [a, b]), .accessDenied)
    XCTAssertEqual(p.queue.count, 0)
    XCTAssertEqual(p.write([], [a]), .ok)
    XCTAssertTrue(p.queue.readable)
    p.queue.closeReceiver { _ in XCTFail() }
    p.queue.closeReceiver { _ in XCTFail() }
    XCTAssertEqual(p.queue.count, 0)
    let c = p.name()
    XCTAssertEqual(p.write([], [c, b]), .accessDenied)
    XCTAssertEqual(p.write([], [c]), .peerClosed)
    XCTAssertFalse(p.src.close(c) { _ in XCTFail() })
    XCTAssertTrue(p.src.close(b) { _ in XCTFail() })
  }
}
