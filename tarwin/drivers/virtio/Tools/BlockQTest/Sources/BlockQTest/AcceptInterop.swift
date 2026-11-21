import TarwinIPC
import TarwinNet
import TarwinObject
import TarwinSyscall

/// Hosted process and port storage. The network worker receives a checksum-
/// validated handshake, and the client can only use the returned type-13 handle.
func withAcceptedEndpoint(
  local: [UInt8], port: UInt16, handshake: (inout TcpService) throws -> Void,
  exchange: (inout TcpConnection) throws -> Void
) throws {
  let ids = KoidSource()
  let headers = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 5)
  let jobs = UnsafeMutableBufferPointer<JobNode>.allocate(capacity: 1)
  let members = UnsafeMutableBufferPointer<JobMember>.allocate(capacity: 1)
  let threads = UnsafeMutableBufferPointer<ThreadSlot>.allocate(capacity: 1)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 3)
  let packets = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 1)
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  threads.initialize(repeating: ThreadSlot())
  packets.initialize(repeating: PortSlot())
  let root = headers.baseAddress!
  let process = root + 1
  let listener = root + 2
  let sink = root + 3
  let child = root + 4
  for (i, k) in [
    TarwinKind.job, TarwinKind.process, TarwinKind.endpoint, TarwinKind.port, TarwinKind.endpoint,
  ].enumerated() {
    (root + i).initialize(
      to: ObjectHeader(
        source: ids, ownerJob: i == 0 ? 0 : root.pointee.koid, kind: k, maximumRights: 15)!)
  }
  let tree = JobTree(
    jobs: jobs, members: members, root: root.pointee,
    limits: JobLimits(
      processes: 1,
      threadsPerProcess: 1, handlesPerProcess: 3, footprint: 8192, cpuShare: 1, maxQos: 2,
      jetsamBand: 2,
      ioRank: 1, entitlements: 0, denials: 0, killOnClose: false))!
  var caller = ProcessExecution(
    header: .init(process), job: tree.root, tree: tree, slots: threads, cells: cells, salt: 103)!
  var ports = TestClient(port: CompletionPort(storage: packets)!, koid: sink.pointee.koid)
  defer {
    caller.withHandles(tree: tree) { $0.drain(retire: { _ in preconditionFailure() }) }
    precondition(tree.detach(caller.member))
    for i in headers.indices { precondition((root + i).pointee.release() == .destroy) }
    cells.deinitialize()
    cells.deallocate()
    headers.deinitialize()
    headers.deallocate()
    packets.deinitialize()
    packets.deallocate()
    threads.deinitialize()
    threads.deallocate()
    members.deinitialize()
    members.deallocate()
    jobs.deinitialize()
    jobs.deallocate()
  }
  guard
    case .installed(let name)? = caller.withHandles(
      tree: tree, { $0.install(.init(listener), rights: 12) }),
    case .installed(let dest)? = caller.withHandles(
      tree: tree, { $0.install(.init(sink), rights: 8) })
  else { throw Failure("Missing listener capabilities") }
  var svc = TcpService(
    koid: listener.pointee.koid, serverEntitled: true, local: local, port: port, interface: 7,
    epoch: 1, backlog: 2, receiveBytes: 2048, bufferBudget: 4096)!
  let peer = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 8)
  defer { peer.deallocate() }
  guard
    case .ready(var op) = EndpointAccept.begin(
      call: TarwinCall.endpointAccept, caller: caller,
      name: name, port: dest, key: 42, peer: peer, service: svc, ports: &ports,
      serverPermitted: true,
      retire: { _ in preconditionFailure() })
  else { throw Failure("Cannot submit accept") }
  defer {
    _ = op.withdraw(at: 2, ports: &ports, releasePin: {}, retire: { _ in preconditionFailure() })
  }
  try handshake(&svc)
  guard let payload = svc.nextForAccept,
    op.poll(
      at: 2, caller: &caller, tree: tree, service: &svc, ports: &ports, serverPermitted: true,
      resolve: { $0 === payload ? .init(child) : nil }, releasePin: {},
      retire: { _ in preconditionFailure() }) == .finished,
    let completion = ports.port.take(), completion.kind == 7, completion.error == 0,
    completion.key == 42,
    ports.references == 0, ports.notifications == 1, svc.ready == 0,
    case .found(let held) = caller.handleReader.pinWithinEpoch(
      completion.result0, kind: TarwinKind.endpoint, need: 12)
  else { throw Failure("Missing Net completion or accepted Endpoint handle") }
  let matchesChild = held.header == UnsafePointer(child)
  held.drop(retire: { _ in preconditionFailure() })
  let path = payload.connection.path
  guard matchesChild, peer[0] == 0, Array(peer[8..<12]) == path.remote,
    UInt16(peer[4]) | UInt16(peer[5]) << 8 == path.remotePort
  else { throw Failure("Wrong endpoint identity or peer") }
  try exchange(&payload.connection)
}
