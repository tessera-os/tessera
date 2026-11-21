import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

/// Nonblocking worker lookup. The caller authorizes destination, source and
/// route for this endpoint/interface generation; a peer cannot supply a route.
public enum DatagramRouteResult {
  case route(UdpRoute)
  case denied, unreachable
}
private struct DatagramSource {
  let spans: [UnsafeRawBufferPointer], bytes: Int, peer: DatagramPeer?
  init?(_ spans: [UnsafeRawBufferPointer], limit: Int, peer: DatagramPeer?) {
    guard !spans.isEmpty, spans.count <= limit else { return nil }
    var n = 0
    for span in spans {
      guard span.count <= 65527 - n, span.isEmpty || span.baseAddress != nil else { return nil }
      n += span.count
    }
    self.spans = spans
    bytes = n
    self.peer = peer
  }
  func packet(_ route: UdpRoute) -> [UInt8] {
    var payload: [UInt8] = []
    payload.reserveCapacity(bytes)
    for span in spans { payload.append(contentsOf: span) }
    guard case .packet(let ip) = udpOutput(route, payload) else { preconditionFailure() }
    return ip
  }
}
/// Completion hands complete packets to the bounded egress queue. It
/// does not imply on-wire delivery. A batch may return a nonempty prefix.
public struct DatagramSend: ~Copyable {
  private var grant: EndpointGrant<UdpMailbox>
  private let messages: [DatagramSource], records: UnsafeMutableRawBufferPointer?
  private init(
    _ grant: consuming EndpointGrant<UdpMailbox>, _ messages: [DatagramSource],
    _ records: UnsafeMutableRawBufferPointer?
  ) {
    self.grant = consume grant
    self.messages = messages
    self.records = records
  }
  public static func begin<P: IoPorts & ~Copyable>(
    call: UInt64, caller: borrowing ProcessExecution, name: UInt64, port: UInt64, key: UInt64,
    flags: UInt32, sources: [UnsafeRawBufferPointer], peer: DatagramPeer?, maxVectors: Int,
    ports: inout P, permitted: Bool,
    resolve: (UnsafePointer<ObjectHeader>) -> UdpMailbox?,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> EndpointIoStart<DatagramSend> {
    guard call == TarwinCall.endpointSend || call == TarwinCall.endpointSendTo, flags & ~1 == 0
    else { return .unsupported }
    guard permitted, caller.exit == nil else { return .denied }
    guard (call == TarwinCall.endpointSendTo) == (peer != nil),
      let m = DatagramSource(sources, limit: maxVectors, peer: peer)
    else { return .invalid }
    return EndpointGrant.acquire(
      caller: caller, name: name, port: port, key: key, rights: 8, ports: &ports, resolve: resolve,
      supports: { peer != nil || (!$0.binding.peer.isEmpty && $0.binding.peerPort != 0) },
      retire: retire
    ) { (g: consuming EndpointGrant<UdpMailbox>) in
      DatagramSend(consume g, [m], nil)
    }
  }
  public static func beginMany<P: IoPorts & ~Copyable>(
    call: UInt64, caller: borrowing ProcessExecution, name: UInt64, port: UInt64, key: UInt64,
    flags: UInt32, sources: [[UnsafeRawBufferPointer]], records: UnsafeMutableRawBufferPointer,
    maxMessages: Int, maxVectors: Int,
    ports: inout P, permitted: Bool, resolve: (UnsafePointer<ObjectHeader>) -> UdpMailbox?,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> EndpointIoStart<DatagramSend> {
    guard call == TarwinCall.endpointSendMany, flags & ~1 == 0 else { return .unsupported }
    guard permitted, caller.exit == nil else { return .denied }
    guard !sources.isEmpty, sources.count <= maxMessages, sources.count <= Int.max / 56,
      records.count == sources.count * 56, records.baseAddress != nil
    else { return .invalid }
    var messages: [DatagramSource] = []
    var left = maxVectors
    for (i, v) in sources.enumerated() {
      guard
        let peer = DatagramPeer(
          record: .init(rebasing: UnsafeRawBufferPointer(records)[i * 56 + 16..<i * 56 + 48])),
        let m = DatagramSource(v, limit: left, peer: peer)
      else { return .invalid }
      left -= v.count
      messages.append(m)
    }
    return EndpointGrant.acquire(
      caller: caller, name: name, port: port, key: key, rights: 8, ports: &ports, resolve: resolve,
      supports: { _ in true }, retire: retire
    ) { (g: consuming EndpointGrant<UdpMailbox>) in DatagramSend(consume g, messages, records) }
  }
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    grant.matches(port: port, operation: operation)
  }
  public mutating func poll<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, permitted: Bool,
    route: (UInt64, UInt32, UInt64, DatagramPeer) -> DatagramRouteResult, releasePins: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> SendProgress {
    guard grant.active else { return .inactive }
    let box = grant.payload
    let binding = box.binding
    var routes: [UdpRoute] = []
    var err: UInt32 = 0
    var room = box.egress.byteLimit - box.egress.bytes
    if !permitted {
      err = 4
    } else if box.closed {
      err = 23
    } else {
      planning: for m in messages {
        guard let peer = m.peer ?? DatagramPeer(address: binding.peer, port: binding.peerPort)
        else {
          err = 23
          break
        }
        let width = binding.family == .v4 ? 4 : 16
        guard peer.address.count == width, peer.scope == 0 || peer.scope == box.interface else {
          err = 64
          break
        }
        let r: UdpRoute
        switch route(binding.process, box.interface, box.epoch, peer) {
        case .route(let value): r = value
        case .denied:
          err = 4
          break planning
        case .unreachable:
          err = 62
          break planning
        }
        guard r.family == binding.family, r.source.count == width, r.sourcePort == binding.port,
          binding.local.isEmpty || r.source == binding.local, r.destination == peer.address,
          r.destinationPort == peer.port, r.hops != 0
        else {
          err = 64
          break
        }
        let total = m.bytes + (width == 4 ? 28 : 48)
        guard width != 4 || total <= 65535, UInt32(total) <= r.mtu, total <= box.egress.byteLimit
        else {
          err = 6
          break
        }
        guard room >= total, routes.count < box.egress.room else { break }
        room -= total
        routes.append(r)
      }
    }
    guard !routes.isEmpty || err != 0 else { return .waiting }
    let messages = self.messages
    let records = self.records
    grant.finish(at: now, ports: &ports, releasePins: releasePins, retire: retire) {
      var p = PortPacket()
      guard !routes.isEmpty else {
        p.error = err
        p.subsystem = 6
        return p
      }
      for i in routes.indices {
        let m = messages[i]
        let r = routes[i]
        box.egress.append(.init(route: r, ip: m.packet(r)))
        if let records {
          storeNetScalar(UInt64(m.bytes), bytes: 8, at: i * 56 + 48, in: records)
          storeNetScalar(0, bytes: 4, at: i * 56 + 12, in: records)
        }
      }
      p.result0 = UInt64(records == nil ? messages[0].bytes : routes.count)
      return p
    }
    return .finished
  }
  @discardableResult public mutating func withdraw<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, releasePins: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    grant.withdraw(at: now, ports: &ports, releasePins: releasePins, retire: retire)
  }
}
