import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinNet

struct AcceptPorts: IoPorts, ~Copyable {
  let id: UInt64
  var port: CompletionPort, refs = 0, wakes = 0
  mutating func retainPort(_ k: UInt64) -> Bool {
    guard k == id else { return false }
    refs += 1
    return true
  }
  mutating func releasePort(_ k: UInt64) {
    XCTAssertEqual(k, id)
    refs -= 1
  }
  mutating func wakePort(_ k: UInt64, count: Int) {
    XCTAssertEqual(k, id)
    wakes += count
  }
  mutating func withLockedPort(_ k: UInt64, _ visit: (inout CompletionPort) -> Void) {
    XCTAssertEqual(k, id)
    visit(&port)
  }
}
private enum Outcome {
  case accepted, receive, send, cancelled, closed, reset, quota, denied, withdrawn
}
private func acceptScenario(_ outcome: Outcome, v6: Bool = false) {
  let ids = KoidSource()
  let headers = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 5)
  let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
  let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 1)
  let slots = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 4)
  let packets = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
  let mem = UnsafeMutableRawBufferPointer.allocate(byteCount: 34, alignment: 1)
  for i in mem.indices { mem[i] = 0xcd }
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  slots.initialize(repeating: ThreadSlot())
  packets.initialize(repeating: PortSlot())
  let h = headers.baseAddress!
  let root = h
  let process = h + 1
  let listener = h + 2
  let sink = h + 3
  let child = h + 4
  for (i, k) in [
    TarwinKind.job, TarwinKind.process, TarwinKind.endpoint, TarwinKind.port, TarwinKind.endpoint,
  ].enumerated() {
    (h + i).initialize(
      to: ObjectHeader(
        source: ids, ownerJob: i == 0 ? 0 : root.pointee.koid, kind: k, maximumRights: 15)!)
  }
  let limits = JobLimits(
    processes: 1, threadsPerProcess: 1, handlesPerProcess: 4, footprint: 1024, cpuShare: 1,
    maxQos: 2, jetsamBand: 1, ioRank: 1, entitlements: 0, denials: 0, killOnClose: false)
  let tree = JobTree(jobs: jobs, members: members, root: root.pointee, limits: limits)!
  var caller = ProcessExecution(
    header: .init(process), job: tree.root, tree: tree, slots: slots, cells: cells, salt: 76)!
  var ports = AcceptPorts(id: sink.pointee.koid, port: CompletionPort(storage: packets)!)
  defer {
    caller.withHandles(tree: tree) { $0.drain(retire: { _ in XCTFail() }) }
    XCTAssertTrue(tree.detach(caller.member))
    for i in 0..<headers.count { XCTAssertEqual((h + i).pointee.release(), .destroy) }
    cells.deinitialize()
    cells.deallocate()
    slots.deinitialize()
    slots.deallocate()
    members.deinitialize()
    members.deallocate()
    jobs.deinitialize()
    jobs.deallocate()
    packets.deinitialize()
    packets.deallocate()
    headers.deinitialize()
    headers.deallocate()
    mem.deallocate()
  }
  func install(_ h: UnsafePointer<ObjectHeader>, rights: UInt64) -> UInt64 {
    guard
      case .installed(let n)? = caller.withHandles(tree: tree, { $0.install(h, rights: rights) })
    else {
      XCTFail()
      return 0
    }
    return n
  }
  let e = install(.init(listener), rights: outcome == .send ? 12 : 4)
  let p = install(.init(sink), rights: 8)
  let denied = install(.init(listener), rights: 0)
  let local: [UInt8] = v6 ? [0xfe, 0x80] + Array(repeating: 0, count: 13) + [2] : [192, 0, 2, 2]
  let remote: [UInt8] = v6 ? [0xfe, 0x80] + Array(repeating: 0, count: 13) + [3] : [192, 0, 2, 3]
  var service = TcpService(
    koid: listener.pointee.koid, serverEntitled: true, local: local, port: 4242, interface: 35,
    epoch: 9, backlog: 2, receiveBytes: 512, bufferBudget: 1024)!
  let pin = UnsafeMutableRawBufferPointer(rebasing: mem[1..<33])
  func begin(_ endpoint: UInt64, _ port: UInt64) -> AcceptStart {
    EndpointAccept.begin(
      call: TarwinCall.endpointAccept, caller: caller, name: endpoint, port: port, key: 75,
      peer: pin, service: service, ports: &ports, serverPermitted: true, retire: { _ in XCTFail() })
  }
  guard case .denied = begin(denied, p), case .wrongType = begin(p, p),
    case .wrongType = begin(e, e),
    case .ready(var accept) = begin(e, p), case .full = begin(e, p)
  else { return XCTFail() }
  var releases = 0
  var payload: TcpAcceptedStream?
  func poll(_ allowed: Bool) -> AcceptProgress {
    accept.poll(
      at: 12, caller: &caller, tree: tree, service: &service, ports: &ports,
      serverPermitted: allowed,
      resolve: { s in
        payload = s
        return .init(child)
      }, releasePin: { releases += 1 }, retire: { _ in XCTFail() })
  }
  XCTAssertEqual(poll(true), .waiting)
  XCTAssertEqual(releases, 0)
  let incoming = TcpPath(
    local: remote, remote: local, localPort: 0xa12b, remotePort: 4242, mtu: 1500)!
  let route = TcpPath(local: local, remote: remote, localPort: 4242, remotePort: 0xa12b, mtu: 1500)!
  func packet(_ seq: UInt32, _ ack: UInt32, _ flags: UInt8, _ data: [UInt8] = []) -> TcpServiceInput
  {
    service.input(
      tcpSegment(incoming.encode(seq, ack, flags, 128, [], data))!, path: route, interface: 35,
      epoch: 9, at: 1, permit: { _ in true }, initial: { (42, nil) },
      emit: { _, b in tcpSegment(b)?.flags == 18 })
  }
  XCTAssertEqual(packet(100, 0, 2), .pending)
  XCTAssertEqual(packet(101, 43, 16, [0, 1]), .ready)
  XCTAssertEqual(packet(103, 43, 24, [2, 255]), .delivered)
  if outcome == .reset { XCTAssertEqual(packet(105, 43, 4), .delivered) }
  if outcome == .quota { _ = install(.init(listener), rights: 0) }
  if outcome == .cancelled || outcome == .withdrawn {
    XCTAssertEqual(
      ports.port.cancel(key: 75) {
        XCTAssertTrue(accept.matches(port: sink.pointee.koid, operation: $0))
      }, 1)
  } else if outcome == .closed {
    ports.port.close()
  }
  if outcome == .withdrawn {
    XCTAssertTrue(
      accept.withdraw(
        at: 12, ports: &ports, releasePin: { releases += 1 }, retire: { _ in XCTFail() }))
  } else {
    XCTAssertEqual(poll(outcome != .denied), .finished)
  }
  XCTAssertEqual(poll(true), .mismatch)
  XCTAssertEqual(releases, 1)
  XCTAssertEqual(ports.refs, 0)
  let result = ports.port.take()
  if outcome != .closed {
    XCTAssertEqual(result?.key, 75)
    XCTAssertEqual(result?.kind, 7)
    XCTAssertEqual(result?.timestamp, 12)
    XCTAssertEqual(ports.wakes, 1)
  } else {
    XCTAssertNil(result)
    XCTAssertEqual(ports.wakes, 0)
  }
  if outcome == .accepted || outcome == .receive || outcome == .send {
    XCTAssertEqual(result?.error, 0)
    XCTAssertEqual(service.ready, 0)
    guard let name = result?.result0,
      case .found(let g) = caller.handleReader.pinWithinEpoch(
        name, kind: TarwinKind.endpoint, need: 4)
    else { return XCTFail() }
    XCTAssertEqual(g.header, UnsafePointer(child))
    XCTAssertEqual(g.rights, outcome == .send ? 12 : 4)
    g.drop(retire: { _ in XCTFail() })
    if outcome == .send {
      checkSend(
        caller: &caller, name: name, denied: denied, port: p, ports: &ports, child: .init(child),
        stream: payload!, incoming: incoming)
    } else if outcome == .receive {
      checkReceive(
        caller: &caller, name: name, denied: denied, port: p, ports: &ports, child: .init(child),
        stream: payload!, incoming: incoming)
    } else {
      var bytes: [UInt8] = []
      XCTAssertEqual(
        payload?.connection.read(upTo: 20) {
          bytes += Array($0)
          return true
        }, 4)
      XCTAssertEqual(bytes, [0, 1, 2, 255])
    }
    var expected = [UInt8](repeating: 0, count: 32)
    expected[0] = v6 ? 1 : 0
    expected[4] = 0x2b
    expected[5] = 0xa1
    expected.replaceSubrange(8..<8 + remote.count, with: remote)
    if v6 {
      expected[6] = 1
      expected[24] = 35
    }
    XCTAssertEqual(Array(mem), [0xcd] + expected + [0xcd])
  } else {
    XCTAssertNil(payload)
    XCTAssertTrue(mem.allSatisfy { $0 == 0xcd })
    XCTAssertEqual(service.ready, outcome == .reset ? 0 : 1)
    if let result {
      XCTAssertEqual(result.result0, 0)
      XCTAssertEqual(
        result.error,
        outcome == .reset ? 61 : outcome == .quota ? 32 : outcome == .denied ? 4 : 26)
    }
  }
}
final class EndpointAcceptTests: XCTestCase {
  func testCompletedBacklogKeepsFifoAndRetriesThirdAckWithoutDataLoss() {
    let local: [UInt8] = [192, 0, 2, 1]
    let remote: [UInt8] = [192, 0, 2, 2]
    guard
      case nil = TcpService(
        koid: 3, serverEntitled: true, local: local, port: 80, interface: 3, epoch: 1,
        backlog: 4, receiveBytes: 1024, bufferBudget: 4095)
    else { return XCTFail() }
    var s = TcpService(
      koid: 3, serverEntitled: true, local: local, port: 80, interface: 3, epoch: 1,
      backlog: 2, receiveBytes: 1024, bufferBudget: 2048)!
    func input(_ port: UInt16, _ syn: Bool) -> TcpServiceInput {
      let out = TcpPath(local: remote, remote: local, localPort: port, remotePort: 80, mtu: 1500)!
      let route = TcpPath(local: local, remote: remote, localPort: 80, remotePort: port, mtu: 1500)!
      let packet = tcpSegment(
        out.encode(syn ? 10 : 11, syn ? 0 : 21, syn ? 2 : 16, 20, [], syn ? [] : [12]))!
      return s.input(
        packet, path: route, interface: 3, epoch: 1, at: 0, permit: { _ in true },
        initial: { (20, nil) }, emit: { _, _ in true })
    }
    XCTAssertEqual(input(12, true), .pending)
    XCTAssertEqual(input(13, true), .pending)
    XCTAssertEqual(input(13, false), .ready)
    XCTAssertEqual(input(12, false), .ready)
    XCTAssertEqual(input(14, true), .pending)
    XCTAssertEqual(input(14, false), .full)
    XCTAssertEqual(s.ready, 2)
    XCTAssertEqual(s.nextForAccept?.connection.path.remotePort, 13)
    s.dequeue()
    XCTAssertEqual(input(14, false), .ready)
    XCTAssertEqual(s.nextForAccept?.connection.path.remotePort, 12)
    s.dequeue()
    XCTAssertEqual(s.nextForAccept?.connection.path.remotePort, 14)
    XCTAssertEqual(s.nextForAccept?.connection.readable, 1)
    s.close()
    XCTAssertEqual(s.ready, 0)
    XCTAssertEqual(input(15, true), .ignored)
  }
  func testHandleRightsAddressesAndQueuedData() {
    acceptScenario(.accepted)
    acceptScenario(.accepted, v6: true)
  }
  func testStreamReceiveThroughAcceptedHandle() {
    acceptScenario(.receive)
    acceptScenario(.receive, v6: true)
  }
  func testStreamSendThroughAcceptedHandle() {
    acceptScenario(.send)
    acceptScenario(.send, v6: true)
  }
  func testCancellationAndClosedPortNeverPublish() {
    for o in [Outcome.cancelled, .withdrawn, .closed] { acceptScenario(o) }
  }
  func testResetQuotaAndRevocation() {
    for o in [Outcome.reset, .quota, .denied] { acceptScenario(o) }
  }
}
