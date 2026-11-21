import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

public enum StreamStart<T: ~Copyable>: ~Copyable {
  case ready(T)
  case unsupported, invalid, invalidHandle, wrongType, denied, notConnected, full
}

/// Bound to the caller's read epoch and the serialized network worker.
/// A live credit owns the port, and the Endpoint grant pins its object.
struct StreamGrant: ~Copyable {
  let stream: TcpAcceptedStream
  private var endpoint: ObjectGrant?, credit: IoReservation?
  private init(
    stream: TcpAcceptedStream, endpoint: consuming ObjectGrant, credit: consuming IoReservation
  ) {
    self.stream = stream
    self.endpoint = consume endpoint
    self.credit = consume credit
  }
  var active: Bool { credit != nil }
  static func acquire<P: IoPorts & ~Copyable, T: ~Copyable>(
    caller: borrowing ProcessExecution, name: UInt64, port: UInt64, key: UInt64, rights: UInt64,
    ports: inout P, resolve: (UnsafePointer<ObjectHeader>) -> TcpAcceptedStream?,
    supports: (TcpAcceptedStream) -> Bool, retire: (UnsafePointer<ObjectHeader>) -> Void,
    make: (consuming StreamGrant) -> T
  ) -> StreamStart<T> {
    let table = caller.handleReader
    switch table.pinWithinEpoch(name, kind: TarwinKind.endpoint, need: rights) {
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .accessDenied: return .denied
    case .found(let e):
      guard let s = resolve(e.header), s.connection.state != .idle, s.connection.state != .synSent
      else {
        e.drop(retire: retire)
        return .notConnected
      }
      guard supports(s) else {
        e.drop(retire: retire)
        return .unsupported
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
        let r = IoReservation(
          port: p.header.pointee.koid, object: e.header.pointee.koid,
          key: key, kind: 7,
          owner: OperationHandle(process: caller.header.pointee.koid, name: name), ports: &ports)
        p.drop(retire: retire)
        guard let r else {
          e.drop(retire: retire)
          return .full
        }
        return .ready(make(StreamGrant(stream: s, endpoint: consume e, credit: consume r)))
      }
    }
  }
  func matches(port: UInt64, operation: PortOperation) -> Bool {
    credit?.matches(port: port, operation: operation) == true
  }
  mutating func finish<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, releasePins: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void, result: () -> PortPacket
  ) {
    credit.take()!.finish(at: now, ports: &ports, result: result)
    releasePins()
    endpoint.take()!.drop(retire: retire)
  }
  mutating func withdraw<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, releasePins: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard active else { return false }
    finish(at: now, ports: &ports, releasePins: releasePins, retire: retire) {
      var p = PortPacket()
      p.error = 26
      p.subsystem = 1
      return p
    }
    return true
  }
}
