import Foundation
import TarwinArchHosted
import TarwinNetHosted
import TarwinObject

/// One policy decision; kernel processes have no verified app ID.
public struct TarwindNetDecision: Sendable {
  public let appID: String?
  public let `protocol`: NetProtocol
  public let endpoint: NetAddress
  public let verdict: NetVerdict
  public let reason: String
  public let socketCreated: Bool
}

extension KernelProcess {
  func recordNetwork(proto: NetProtocol, endpoint: NetAddress, verdict: NetVerdict,
    reason: String, socketCreated: Bool) {
    if networkDecisions.count == 64 { networkDecisions.removeFirst() }
    networkDecisions.append(TarwindNetDecision(appID: verifiedAppID, protocol: proto,
      endpoint: endpoint, verdict: verdict, reason: reason, socketCreated: socketCreated))
  }

  func networkSocket(proto: NetProtocol, direction: NetDirection, endpoint: NetAddress,
    create: () throws -> HostedSocketEndpoint) throws -> HostedSocketEndpoint {
    let flow = NetFlow(app: networkAppID, proto: proto, direction: direction, address: endpoint)
    let verdict = network.policy.check(flow)
    if case .deny(let reason) = verdict {
      recordNetwork(proto: proto, endpoint: endpoint, verdict: verdict, reason: reason, socketCreated: false)
      throw NetError.denied(reason)
    }
    do {
      let socket = try create()
      recordNetwork(proto: proto, endpoint: endpoint, verdict: .allow, reason: "policy", socketCreated: true)
      return socket
    } catch {
      if case NetError.denied(let reason) = error {
        recordNetwork(proto: proto, endpoint: endpoint, verdict: .deny(reason), reason: reason, socketCreated: false)
      } else {
        recordNetwork(proto: proto, endpoint: endpoint, verdict: .allow, reason: "host failure", socketCreated: false)
      }
      throw error
    }
  }
}

/// Wait on readinessHandle with Object.wait: readable=1, writable=2, closed=4.
public final class TarwindSocket: @unchecked Sendable {
  public let readinessHandle: UInt64
  let process: TarwindProcessID
  let endpoint: HostedSocketEndpoint
  let header: UnsafeMutablePointer<ObjectHeader>
  weak var state: KernelState?
  var tokens: [UInt32: HostEventToken] = [:]
  init(state: KernelState, process: TarwindProcessID, endpoint: HostedSocketEndpoint,
    header: UnsafeMutablePointer<ObjectHeader>, handle: UInt64) {
    self.state = state; self.process = process; self.endpoint = endpoint
    self.header = header; readinessHandle = handle
  }
  public var local: NetAddress? { state?.lock.withLock { endpoint.local } }
  public func connectResult() -> NetError?? {
    guard let state else { return .some(.closed) }
    return state.lock.withLock { endpoint.connectResult() }
  }
  public func send(_ bytes: UnsafeRawBufferPointer) throws -> NetIO {
    guard let state else { throw NetError.closed }
    return try state.lock.withLock {
      guard !endpoint.isClosed else { throw NetError.closed }
      let result = endpoint.send(bytes)
      try state.armSocket(self, bit: 2)
      return result
    }
  }
  public func receive(into bytes: UnsafeMutableRawBufferPointer) throws -> NetIO {
    guard let state else { throw NetError.closed }
    return try state.lock.withLock {
      guard !endpoint.isClosed else { throw NetError.closed }
      let result = endpoint.receive(into: bytes)
      try state.armSocket(self, bit: 1)
      return result
    }
  }
  public func sendDatagram(_ bytes: UnsafeRawBufferPointer, to peer: NetAddress) throws -> NetIO {
    guard let state else { throw NetError.closed }
    return try state.lock.withLock {
      guard !endpoint.isClosed else { throw NetError.closed }
      let result = try endpoint.sendDatagram(bytes, to: peer)
      try state.armSocket(self, bit: 2)
      return result
    }
  }
  public func receiveDatagram(into bytes: UnsafeMutableRawBufferPointer) throws -> (Int, NetAddress)? {
    guard let state else { throw NetError.closed }
    return try state.lock.withLock {
      guard !endpoint.isClosed else { throw NetError.closed }
      let result = try endpoint.receiveDatagram(into: bytes)
      try state.armSocket(self, bit: 1)
      return result
    }
  }
  public func close() {
    guard let state else { return }
    state.lock.withLock { state.closeSocket(self) }
  }
}

extension KernelState {
  func armSocket(_ socket: TarwindSocket, bit: UInt32) throws {
    _ = socket.header.pointee.updateSignals(clear: bit, set: 0)
    guard socket.tokens[bit] == nil else { return }
    let token = try events.registerFileDescriptor(socket.endpoint.fd, write: bit == 2)
    socket.tokens[bit] = token
    socketEvents[token] = (socket, bit)
  }
  func registerSocket(_ endpoint: HostedSocketEndpoint, process: TarwindProcessID) throws -> TarwindSocket {
    guard !stopped, let record = processes[process], headers.count < 1024,
      let value = ObjectHeader(source: source, ownerJob: 1, kind: TarwinKind.event, maximumRights: 128)
    else { endpoint.close(); throw TarwindError.invalidProcess }
    let header = arena.store(consume value)
    headers.append(header)
    guard case .installed(let handle) = record.table.pointee.install(UnsafePointer(header), rights: 128) else {
      _ = header.pointee.release(); endpoint.close(); throw TarwindError.unavailable
    }
    let socket = TarwindSocket(state: self, process: process, endpoint: endpoint, header: header, handle: handle)
    sockets[header.pointee.koid] = socket
    do {
      try armSocket(socket, bit: 1)
      if endpoint.kind != .listener { try armSocket(socket, bit: 2) }
    } catch {
      closeSocket(socket)
      _ = record.table.pointee.close(handle, retire: { retired.append($0) })
      throw error
    }
    return socket
  }
  func networkReady(_ event: HostEvent) {
    guard let (socket, bit) = socketEvents.removeValue(forKey: event.token) else { return }
    try? events.cancel(event.token)
    socket.tokens[bit] = nil
    _ = socket.header.pointee.updateSignals(clear: 0, set: bit)
    notify(UnsafePointer(socket.header))
  }
  func closeSocket(_ socket: TarwindSocket) {
    guard sockets.removeValue(forKey: socket.header.pointee.koid) != nil else { return }
    for token in socket.tokens.values { try? events.cancel(token); socketEvents[token] = nil }
    socket.tokens.removeAll()
    socket.endpoint.close()
    _ = socket.header.pointee.updateSignals(clear: 3, set: 4)
    notify(UnsafePointer(socket.header))
    let waiting = pending.values.filter { $0.object == UnsafePointer(socket.header) }
    for wait in waiting {
      _ = objectWaits.pointee.finish(wait.ticket, reason: .cancelled, change: { changed($0) })
    }
    if socket.header.pointee.release() == .destroy { retired.append(UnsafePointer(socket.header)) }
  }
}

extension Tarwind {
  public func networkDecisions(process: TarwindProcessID) -> [TarwindNetDecision] {
    state.lock.withLock { state.processes[process]?.networkDecisions ?? [] }
  }
  public func connectNetwork(process: TarwindProcessID, to peer: NetAddress) throws -> TarwindSocket {
    try state.lock.withLock {
      guard !state.stopped, let record = state.processes[process] else { throw TarwindError.invalidProcess }
      let endpoint = try record.networkSocket(proto: .tcp, direction: .outbound, endpoint: peer) {
        try record.network.connect(app: record.networkAppID, to: peer)
      }
      return try state.registerSocket(endpoint, process: process)
    }
  }
  public func listenNetwork(process: TarwindProcessID, on local: NetAddress) throws -> TarwindSocket {
    try state.lock.withLock {
      guard !state.stopped, let record = state.processes[process] else { throw TarwindError.invalidProcess }
      let endpoint = try record.networkSocket(proto: .tcp, direction: .listen, endpoint: local) {
        try record.network.listen(app: record.networkAppID, on: local)
      }
      return try state.registerSocket(endpoint, process: process)
    }
  }
  public func acceptNetwork(_ listener: TarwindSocket) throws -> TarwindSocket {
    try state.lock.withLock {
      guard listener.state === state, !listener.endpoint.isClosed else { throw NetError.closed }
      defer { try? state.armSocket(listener, bit: 1) }
      return try state.registerSocket(listener.endpoint.accept(), process: listener.process)
    }
  }
  public func datagramNetwork(process: TarwindProcessID, on local: NetAddress) throws -> TarwindSocket {
    try state.lock.withLock {
      guard !state.stopped, let record = state.processes[process] else { throw TarwindError.invalidProcess }
      let endpoint = try record.networkSocket(proto: .udp, direction: .listen, endpoint: local) {
        try record.network.datagram(app: record.networkAppID, on: local)
      }
      return try state.registerSocket(endpoint, process: process)
    }
  }
}
