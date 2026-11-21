import TarwinIPC
import TarwinIPCChannels
import TarwinObject
import TarwinSched
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
  func write(_ bytes: [UInt8], _ names: [UInt64] = [], invalidate: (UInt64) -> Void = { _ in })
    -> ChannelStatus
  {
    bytes.withUnsafeBytes { b in
      names.withUnsafeBufferPointer { n in
        queue.write(b, names: n, from: &src, invalidate: invalidate) { _ in XCTFail() }
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
  func testMoveCancelsOnlyOperationsUsingThatNameInThisProcess() {
    let p = Pair()
    let moved = p.name(6)
    let duplicate = p.name(6)
    let denied = p.name(4)
    var storage = [PortSlot](repeating: PortSlot(), count: 4)
    storage.withUnsafeMutableBufferPointer { slab in
      var port = CompletionPort(storage: slab)!
      let a = OperationHandle(process: 10, name: moved)!
      let b = OperationHandle(process: 10, name: duplicate)!
      let c = OperationHandle(process: 11, name: moved)!
      let ops = [a, b, c, a].map { port.reserve(object: 22, key: 15, kind: 1, owner: $0)! }
      var cancelled: [PortOperation] = []
      func invalidate(_ name: UInt64) {
        _ = port.cancel(owner: OperationHandle(process: 10, name: name)!) { cancelled.append($0) }
      }
      XCTAssertEqual(p.write([], [moved, denied], invalidate: invalidate), .accessDenied)
      XCTAssertTrue(cancelled.isEmpty)
      XCTAssertEqual(p.write([], [moved], invalidate: invalidate), .ok)
      XCTAssertEqual(cancelled, [ops[0], ops[3]])
      XCTAssertNil(port.take())
      for (i, op) in ops.enumerated() {
        var committed = false
        XCTAssertEqual(
          port.finish(op, at: 23) {
            committed = true
            return PortPacket()
          }, 1)
        XCTAssertEqual(committed, i == 1 || i == 2)
        XCTAssertEqual(port.take()?.error, committed ? 0 : 26)
      }
      var invalidated: [UInt64] = []
      p.queue.closeReceiver { _ in XCTFail() }
      XCTAssertEqual(p.write([], [duplicate], invalidate: { invalidated.append($0) }), .peerClosed)
      XCTAssertEqual(invalidated, [duplicate])
    }
  }
  private func withPair(_ body: (inout ChannelPair, UnsafeMutablePointer<ObjectHeader>) -> Void) {
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
    body(&q, heads)
    q.close(.a) { _ in XCTFail() }
    q.close(.b) { _ in XCTFail() }
  }
  func testPairPublishesReadinessOnTheCorrectEnd() {
    let pair = Pair()
    withPair { q, heads in
      XCTAssertEqual(heads.pointee.signals, 2)
      let a = pair.name(6)
      XCTAssertEqual(
        [a].withUnsafeBufferPointer { names in
          [UInt8(21)].withUnsafeBytes {
            q.send(
              from: .a, $0, names: names, table: &pair.src, invalidate: { XCTAssertEqual($0, a) }
            ) { _ in XCTFail() }
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
  }

  func testInlineRoundTripNeverQueuesAndHandsEachGrantToTheRightTable() {
    let pair = Pair()
    withPair { q, _ in
      var cpu = BootstrapCPU(now: 0, identity: 1)
      for (i, qos) in [(1, SchedClass.background), (2, SchedClass.interactive)] {
        XCTAssertTrue(cpu.create(id: UInt64(i), qos: qos))
      }
      XCTAssertTrue(cpu.wake(1, now: 0))
      XCTAssertEqual(cpu.select(now: 0), 1)
      let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 8)
      let names = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 8)
      let size = UnsafeMutableBufferPointer<ChannelSize>.allocate(capacity: 2)
      bytes.initializeMemory(as: UInt8.self, repeating: 0xcc)
      names.initialize(repeating: 0)
      size.initialize(repeating: ChannelSize())
      defer {
        bytes.deallocate()
        names.deinitialize()
        names.deallocate()
        size.deinitialize()
        size.deallocate()
      }
      func area(_ i: Int, _ table: borrowing HandleTable) -> ServiceArea {
        ServiceArea(
          bytes: .init(rebasing: bytes[i * 128..<(i + 1) * 128]),
          names: .init(rebasing: names[i * 4..<(i + 1) * 4]), size: size.baseAddress! + i,
          table: table)
      }
      let server = area(1, pair.dst)
      let client = area(0, pair.src)
      guard let wait = q.waitForRequest(at: .b, into: server, cpu: &cpu, now: 0)
      else { return XCTFail() }
      XCTAssertTrue(cpu.wake(2, now: 0))
      XCTAssertEqual(cpu.select(now: 0), 2)
      let source = pair.name()
      let denied = pair.name(4)
      func send(
        _ names: [UInt64], _ count: Int, _ end: ChannelEnd = .a,
        _ dst: ServiceArea? = nil
      ) -> DirectServiceCall? {
        var pending: DirectServiceCall?
        names.withUnsafeBufferPointer { n in
          [UInt8](repeating: 17, count: count).withUnsafeBytes { b in
            pending = q.directCall(
              from: end, waiting: wait, transaction: 9, deadline: 10, now: 2,
              cpu: &cpu, message: .init(bytes: b, names: n), replyTo: dst ?? client,
              sender: &pair.src, receiver: &pair.dst, invalidate: { XCTAssertEqual($0, source) })
          }
        }
        return consume pending
      }
      for (n, count, end, area): ([UInt64], Int, ChannelEnd, ServiceArea?) in [
        ([source, denied], 64, .a, nil), ([source, source], 64, .a, nil),
        ([source], 129, .a, nil), ([source], 128, .b, nil), ([source], 64, .a, server),
      ] {
        XCTAssertTrue(send(n, count, end, area) == nil)
        XCTAssertEqual(pair.src.count, 2)
        XCTAssertEqual(pair.dst.count, 0)
        XCTAssertEqual(size[1].bytes, 0)
        XCTAssertEqual(bytes[128], 0xcc)
        XCTAssertEqual(cpu.running, 2)
      }
      guard var call = send([source], 128) else { return XCTFail() }
      XCTAssertEqual(size[1].bytes, 128)
      XCTAssertEqual(size[1].handles, 1)
      XCTAssertTrue(bytes[128...].allSatisfy { $0 == 17 })
      XCTAssertNil(q.peek(at: .b))
      XCTAssertFalse(pair.src.close(source) { _ in XCTFail() })
      XCTAssertNotEqual(names[4], source)
      XCTAssertEqual(cpu.running, 1)
      XCTAssertEqual(cpu.charging, 2)
      let reply = ServiceMessage(
        bytes: .init(rebasing: UnsafeRawBufferPointer(bytes)[128...]),
        names: .init(start: names.baseAddress! + 4, count: 1))
      XCTAssertFalse(
        call.reply(
          transaction: 8, channel: q, now: 6, cpu: &cpu, message: reply,
          sender: &pair.dst, receiver: &pair.src, invalidate: { _ in XCTFail() }))
      XCTAssertEqual(bytes[0], 0xcc)
      XCTAssertTrue(
        call.reply(
          transaction: 9, channel: q, now: 7, cpu: &cpu, message: reply,
          sender: &pair.dst, receiver: &pair.src, invalidate: { XCTAssertEqual($0, names[4]) }))
      XCTAssertEqual(call.state, .replied)
      XCTAssertEqual(size[0].bytes, 128)
      XCTAssertEqual(size[0].handles, 1)
      XCTAssertEqual(bytes[127], 17)
      XCTAssertTrue(pair.src.close(names[0]) { _ in XCTFail() })
      XCTAssertNil(q.peek(at: .a))
      XCTAssertEqual(cpu.running, 2)
      XCTAssertFalse(call.cancel(peerClosed: true, now: 10, cpu: &cpu))
      let empty = ServiceMessage(
        bytes: .init(start: nil, count: 0), names: .init(start: nil, count: 0))
      for (n, terminal) in [ServiceState.timedOut, .cancelled, .peerClosed].enumerated() {
        let now = UInt64(20 + 4 * n)
        XCTAssertTrue(cpu.sleepRunning(now: now))
        XCTAssertEqual(cpu.select(now: now), 1)
        guard let next = q.waitForRequest(at: .b, into: server, cpu: &cpu, now: now),
          cpu.wake(2, now: now), cpu.select(now: now) == 2,
          var pending = q.directCall(
            from: .a, waiting: next, transaction: 5, deadline: now + 2,
            now: now, cpu: &cpu, message: empty, replyTo: client, sender: &pair.src,
            receiver: &pair.dst, invalidate: { _ in XCTFail() })
        else { return XCTFail() }
        if terminal == .peerClosed { q.close(.b) { _ in XCTFail() } }
        if terminal == .cancelled {
          XCTAssertTrue(pending.cancel(peerClosed: false, now: now + 1, cpu: &cpu))
        }
        XCTAssertFalse(
          pending.reply(
            transaction: 5, channel: q,
            now: terminal == .timedOut ? now + 2 : now + 1, cpu: &cpu, message: empty,
            sender: &pair.dst, receiver: &pair.src, invalidate: { _ in XCTFail() }))
        XCTAssertEqual(pending.state, terminal)
        XCTAssertEqual(size[0].bytes, 128, "late reply must not publish to the caller")
        XCTAssertEqual(cpu.running, 2)
      }
    }
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
