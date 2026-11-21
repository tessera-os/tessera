import Foundation
import TarwinArchHosted
import TarwinNetHosted
import TarwinObject

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
  public func connectNetwork(process: TarwindProcessID, to peer: NetAddress) throws -> TarwindSocket {
    try state.lock.withLock {
      guard !state.stopped, state.processes[process] != nil else { throw TarwindError.invalidProcess }
      return try state.registerSocket(state.network.connect(app: String(process.value), to: peer), process: process)
    }
  }
  public func listenNetwork(process: TarwindProcessID, on local: NetAddress) throws -> TarwindSocket {
    try state.lock.withLock {
      guard !state.stopped, state.processes[process] != nil else { throw TarwindError.invalidProcess }
      return try state.registerSocket(state.network.listen(app: String(process.value), on: local), process: process)
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
      guard !state.stopped, state.processes[process] != nil else { throw TarwindError.invalidProcess }
      return try state.registerSocket(state.network.datagram(app: String(process.value), on: local), process: process)
    }
  }
}
