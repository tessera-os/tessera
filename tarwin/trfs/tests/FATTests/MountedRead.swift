import TRFS
import TarwinFAT
import TarwinFsWire
import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinReadOnlyFS
import TarwinSyscall
import XCTest

private struct Ports: IoPorts, ~Copyable {
  let koid: UInt64
  var port: CompletionPort, refs = 0, wakes = 0
  mutating func retainPort(_ k: UInt64) -> Bool {
    guard k == koid else { return false }
    refs += 1
    return true
  }
  mutating func releasePort(_ k: UInt64) {
    XCTAssertEqual(k, koid)
    refs -= 1
  }
  mutating func wakePort(_ k: UInt64, count: Int) {
    XCTAssertEqual(k, koid)
    wakes += count
  }
  mutating func withLockedPort(_ k: UInt64, _ visit: (inout CompletionPort) -> Void) {
    XCTAssertEqual(k, koid)
    visit(&port)
  }
}
private struct Staging: FatShares {
  var id: UInt64 = 0, ready: [UInt8] = [], granted = false
  let bytes: UInt32
  func load(request: UInt64, share: UInt64, length: UInt32) -> [UInt8]? { nil }
  mutating func store(request: UInt64, share: UInt64, capacity: UInt32, bytes: [UInt8]) -> Bool {
    guard granted, request == id, share == 91, capacity == self.bytes, bytes.count <= capacity
    else { return false }
    ready = bytes
    return true
  }
}
private enum Outcome { case success, cancel, closed, removed, badCopy, unpublished }
private func runRead<V: ReadOnlyVolume>(
  _ volume: V, node: UInt64, offset: UInt64, expected: [UInt8], outcome: Outcome
) {
  mounted(volume) { session, server in
    let ids = KoidSource()
    func object(_ kind: UInt32, _ rights: UInt64) -> UnsafeMutablePointer<ObjectHeader> {
      let ptr = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
      ptr.initialize(to: ObjectHeader(source: ids, ownerJob: 1, kind: kind, maximumRights: rights)!)
      return ptr
    }
    let file = object(TarwinKind.file, 7)
    let port = object(TarwinKind.port, 8)
    let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 8)
    let pbuf = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
    pbuf.initialize(repeating: PortSlot())
    var table = HandleTable(storage: cells, salt: 2)!
    var ports = Ports(koid: port.pointee.koid, port: CompletionPort(storage: pbuf)!)
    func install(_ result: HandleMutation) -> UInt64 {
      guard case .installed(let n) = result else {
        XCTFail()
        return 0
      }
      return n
    }
    let src = install(table.install(file, rights: 7))
    let read = install(table.derive(src, rights: 4, duplicate: true))
    let none = install(table.derive(src, rights: 0, duplicate: true))
    let sink = install(table.install(port, rights: 8))
    let noPost = install(table.install(port, rights: 0))
    var retired = 0
    func retire(_ h: UnsafePointer<ObjectHeader>) {
      XCTAssertEqual(h, UnsafePointer(file))
      retired += 1
    }
    defer {
      table.drain(retire: { _ in XCTFail() })
      XCTAssertEqual(port.pointee.release(), .destroy)
      for h in [file, port] {
        h.deinitialize(count: 1)
        h.deallocate()
      }
      pbuf.deinitialize()
      pbuf.deallocate()
      cells.deinitialize()
      cells.deallocate()
    }
    let n = UInt32(expected.count + 8)
    let share = FsShare(volume: 9, id: 91, backing: 77, offset: 0, length: n, writable: true)
    func begin(_ name: UInt64, _ portName: UInt64, _ call: UInt64 = TarwinCall.fileRead)
      -> FileReadStart
    {
      MountedRead.begin(
        call: call, name: name, port: portName, key: 42, offset: offset, length: n, stage: share,
        table: table.reader, ports: &ports,
        resolve: { h in
          h == UnsafePointer(file) ? MountedFile(volume: 9, epoch: 17, node: node) : nil
        }, retire: retire)
    }
    guard case .denied = begin(none, sink), case .denied = begin(read, noPost),
      case .wrongType = begin(sink, sink), case .invalidHandle = begin(0, sink),
      case .unsupported = begin(read, sink, TarwinCall.fileWrite)
    else { return XCTFail("capability check") }
    guard case .ready(var op) = begin(read, sink), case .full = begin(src, sink) else {
      return XCTFail("missing bounded reservation")
    }
    XCTAssertEqual(ports.refs, 1)
    for h in [src, read, none] { XCTAssertTrue(table.close(h, retire: retire)) }
    XCTAssertNotEqual(file.pointee.release(), .destroy)
    XCTAssertEqual(retired, 0)
    var stage = Staging(bytes: n)
    var released = 0
    var commits = 0
    var dest = [UInt8](repeating: 0xde, count: Int(n))
    if outcome == .unpublished {
      XCTAssertFalse(
        op.abandon(at: 1, ports: &ports, drain: { false }, release: { XCTFail() }, retire: retire))
      XCTAssertTrue(
        op.abandon(
          at: 2, ports: &ports, drain: { true }, release: { released += 1 }, retire: retire))
    } else {
      guard case .ring(.transferred) = op.publish(to: &session) else {
        return XCTFail("not published")
      }
      XCTAssertEqual(op.publish(to: &session), .rejected)
      stage.id = op.request
      stage.granted = true
      XCTAssertFalse(
        op.abandon(
          at: 2, ports: &ports,
          drain: {
            XCTFail()
            return true
          }, release: { XCTFail() }, retire: retire))
      var receipt: FsReceipt?
      if outcome == .removed {
        XCTAssertFalse(session.disconnectRetired(revoke: { _ in false }, fail: { _ in XCTFail() }))
        XCTAssertTrue(
          session.disconnectRetired(
            revoke: { _ in
              stage.granted = false
              return true
            }, fail: { receipt = $0 }))
      } else {
        XCTAssertEqual(server.step(shares: &stage, signalSpace: {}, signalReply: {}), .replied)
        XCTAssertEqual(
          session.pollRetired(signalSpace: {}, revoke: { _ in false }, deliver: { _ in XCTFail() }),
          .retiring)
        if outcome == .cancel {
          var token: PortOperation?
          XCTAssertEqual(ports.port.cancel(key: 42) { token = $0 }, 1)
          XCTAssertTrue(op.matches(port: ports.koid, operation: token!))
        } else if outcome == .closed {
          ports.port.close()
        }
        XCTAssertNil(ports.port.take())
        XCTAssertEqual(retired, 0)
        XCTAssertEqual(
          session.pollRetired(
            signalSpace: {},
            revoke: { r in
              XCTAssertEqual(r.output, 91)
              stage.granted = false
              return true
            }, deliver: { receipt = $0 }), .completed)
      }
      guard let receipt else { return XCTFail("missing receipt") }
      XCTAssertTrue(
        op.finish(
          receipt, at: 3, ports: &ports,
          commit: { s, count in
            XCTAssertEqual(s, 91)
            XCTAssertFalse(stage.granted)
            commits += 1
            guard outcome != .badCopy else { return false }
            dest.replaceSubrange(0..<Int(count), with: stage.ready.prefix(Int(count)))
            return true
          }, release: { released += 1 }, retire: retire))
      XCTAssertFalse(
        op.finish(
          receipt, at: 4, ports: &ports,
          commit: { _, _ in
            XCTFail()
            return false
          }, release: { XCTFail() }, retire: retire))
    }
    XCTAssertEqual(ports.refs, 0)
    XCTAssertEqual(released, 1)
    XCTAssertEqual(retired, 1)
    let packet = ports.port.take()
    if outcome == .closed {
      XCTAssertNil(packet)
      XCTAssertEqual(ports.wakes, 0)
    } else {
      XCTAssertEqual(packet?.kind, 3)
      XCTAssertEqual(packet?.key, 42)
      XCTAssertEqual(ports.wakes, 1)
      let code: UInt32 =
        switch outcome {
        case .cancel: 26
        case .removed, .unpublished: 70
        case .badCopy: 90
        default: 0
        }
      XCTAssertEqual(packet?.error, code)
      XCTAssertEqual(packet?.result0, outcome == .success ? UInt64(expected.count) : 0)
    }
    if outcome == .success {
      XCTAssertEqual(Array(dest.prefix(expected.count)), expected)
      XCTAssertTrue(dest.dropFirst(expected.count).allSatisfy { $0 == 0xde })
    } else {
      XCTAssertTrue(dest.allSatisfy { $0 == 0xde })
    }
    XCTAssertEqual(
      commits, outcome == .badCopy || (outcome == .success && !expected.isEmpty) ? 1 : 0)
  }
}
func readMountedMedia<V: ReadOnlyVolume>(_ v: V, node: UInt64, expected: [UInt8]) {
  runRead(v, node: node, offset: 0, expected: expected, outcome: .success)
}
final class MountedReadTests: XCTestCase {
  func testIssuedFileReadsOutliveHandleCloseAndCommitOnlyAfterRetirement() throws {
    let v = try FatVolume(sample())
    let node = try v.lookup(parent: v.root, name: Array("README.TXT".utf8))
    for result: Outcome in [.success, .badCopy, .cancel, .closed, .removed, .unpublished] {
      runRead(v, node: node, offset: 512, expected: [1, 2, 3, 4, 5, 6], outcome: result)
    }
    runRead(v, node: node, offset: 518, expected: [], outcome: .success)
  }
}
