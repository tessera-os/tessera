import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

public enum AcceptStart: ~Copyable {
  case ready(EndpointAccept)
  case unsupported, invalid, invalidHandle, wrongType, denied, notListening, full
}
public enum AcceptProgress { case mismatch, waiting, finished }

/// Serialize outstanding accepts in submission order under the endpoint
/// worker. Bind process to the submitting handle table, not the port's owner.
public struct EndpointAccept: ~Copyable {
  private let process: UInt64, epoch: UInt64
  private var endpoint: ObjectGrant?, credit: IoReservation?
  private let peer: UnsafeMutableRawBufferPointer?
  private init(
    process: UInt64, epoch: UInt64, endpoint: consuming ObjectGrant,
    credit: consuming IoReservation,
    peer: UnsafeMutableRawBufferPointer?
  ) {
    self.process = process
    self.epoch = epoch
    self.endpoint = consume endpoint
    self.credit = consume credit
    self.peer = peer
  }
  /// peer, if present, is a validated, writable VM pin, never a raw user
  /// address. On rejection the caller still owns that pin. Hold a read epoch.
  public static func begin<P: IoPorts & ~Copyable>(
    call: UInt64, caller: borrowing ProcessExecution, name: UInt64, port: UInt64,
    key: UInt64, peer: UnsafeMutableRawBufferPointer?, service: borrowing TcpService,
    ports: inout P, serverPermitted: Bool, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> AcceptStart {
    guard call == TarwinCall.endpointAccept else { return .unsupported }
    guard peer == nil || (peer?.count == 32 && peer?.baseAddress != nil) else { return .invalid }
    guard caller.exit == nil, serverPermitted else { return .denied }
    let process = caller.header.pointee.koid
    let table = caller.handleReader
    switch table.pinWithinEpoch(name, kind: TarwinKind.endpoint, need: 4) {
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .accessDenied: return .denied
    case .found(let e):
      guard e.header.pointee.koid == service.koid, !service.closed else {
        e.drop(retire: retire)
        return .notListening
      }
      switch table.pinWithinEpoch(port, kind: TarwinKind.port, need: 8) {
      case .invalidHandle:
        e.drop(retire: retire)
        return .invalidHandle
      case .wrongType:
        e.drop(retire: retire)
        return .wrongType
      case .accessDenied:
        e.drop(retire: retire)
        return .denied
      case .found(let p):
        let credit = IoReservation(
          port: p.header.pointee.koid, object: service.koid, key: key, kind: 7, ports: &ports)
        p.drop(retire: retire)
        guard let credit else {
          e.drop(retire: retire)
          return .full
        }
        return .ready(
          EndpointAccept(
            process: process, epoch: service.epoch, endpoint: consume e,
            credit: consume credit, peer: peer))
      }
    }
  }
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    credit?.matches(port: port, operation: operation) == true
  }
  private static func address(
    _ path: TcpPath, interface: UInt32, to b: UnsafeMutableRawBufferPointer
  ) {
    for i in 0..<32 { b[i] = 0 }
    b[0] = path.remote.count == 4 ? 0 : 1
    b[4] = UInt8(truncatingIfNeeded: path.remotePort)
    b[5] = UInt8(path.remotePort >> 8)
    for i in path.remote.indices { b[8 + i] = path.remote[i] }
    if path.remote.count == 16, path.remote[0] == 0xfe, path.remote[1] & 0xc0 == 0x80 {
      b[6] = 1
      for i in 0..<4 { b[24 + i] = UInt8(truncatingIfNeeded: interface >> (8 * i)) }
    }
  }
  /// Caller holds the submitting process's table writer lock. resolve returns
  /// the live, independently retained Endpoint header already bound to that
  /// exact stream. It may only inspect prepared kernel state, not fault, sleep
  /// or reenter the port. Native table/port locks need one consistent order.
  public mutating func poll<P: IoPorts & ~Copyable>(
    at now: UInt64, caller: inout ProcessExecution, tree: borrowing JobTree,
    service: inout TcpService, ports: inout P, serverPermitted: Bool,
    resolve: (TcpAcceptedStream) -> UnsafePointer<ObjectHeader>?,
    releasePin: () -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> AcceptProgress {
    guard credit != nil, caller.header.pointee.koid == process,
      service.koid == endpoint?.header.pointee.koid,
      epoch == service.epoch
    else { return .mismatch }
    let s = service.nextForAccept
    let stopping = caller.exit != nil || tree.returnGate(caller.member) == .terminate
    guard service.closed || stopping || !serverPermitted || s != nil else {
      return .waiting
    }
    let peer = self.peer
    let rights = endpoint?.rights ?? 0
    let iface = service.interface
    let closed = service.closed
    let koid = service.koid
    var dequeue = false
    credit.take()!.finish(at: now, ports: &ports) {
      var p = PortPacket()
      if !serverPermitted {
        p.error = 4
      } else if closed || stopping {
        p.error = 23
      } else if let s {
        if s.connection.state == .reset || s.connection.state == .timedOut {
          p.error = 61
          dequeue = true
        } else if caller.withHandles(
          tree: tree,
          { table -> Void in
            if table.freeCount == 0 {
              p.error = 32
            } else if let h = resolve(s), h.pointee.kind == TarwinKind.endpoint,
              h.pointee.koid != koid,
              case .installed(let name) = table.install(h, rights: h.pointee.maximumRights & rights)
            {
              if let peer { Self.address(s.connection.path, interface: iface, to: peer) }
              p.result0 = name
              dequeue = true
            } else {
              p.error = 90
            }
          }) == nil
        {
          p.error = 23
        }
      }
      if p.error != 0 { p.subsystem = 6 }
      return p
    }
    if dequeue { service.dequeue() }
    releasePin()
    self.endpoint.take()!.drop(retire: retire)
    return .finished
  }
  /// The port schedules cancellation/close against the exact operation. No
  /// peer bytes, handle or queued connection are consumed by a withdrawn wait.
  public mutating func withdraw<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P,
    releasePin: () -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard let c = credit.take() else { return false }
    c.finish(at: now, ports: &ports) {
      var p = PortPacket()
      p.error = 23
      p.subsystem = 6
      return p
    }
    releasePin()
    endpoint.take()!.drop(retire: retire)
    return true
  }
}
