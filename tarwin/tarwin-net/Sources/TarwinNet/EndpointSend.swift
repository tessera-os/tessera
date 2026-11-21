import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

public typealias SendStart = StreamStart<EndpointSend>
public enum SendProgress { case waiting, finished, inactive }

/// Completion means the stream owns the reported prefix, not that a NIC
/// transmitted it or the peer acknowledged it. Pump TCP outside the port lock.
public struct EndpointSend: ~Copyable {
  private var grant: StreamGrant
  private let sources: [UnsafeRawBufferPointer], count: Int, flags: UInt32
  private init(
    _ sources: [UnsafeRawBufferPointer], _ count: Int, _ flags: UInt32,
    _ grant: consuming StreamGrant
  ) {
    self.grant = consume grant
    self.sources = sources
    self.count = count
    self.flags = flags
  }
  /// Sources are already validated read pins. The submitter holds the handle
  /// read epoch, and still owns all pins if submission is rejected.
  public static func begin<P: IoPorts & ~Copyable>(
    call: UInt64, caller: borrowing ProcessExecution, name: UInt64, port: UInt64, key: UInt64,
    flags: UInt32, sources: [UnsafeRawBufferPointer], maxVectors: Int,
    ports: inout P, permitted: Bool, resolve: (UnsafePointer<ObjectHeader>) -> TcpAcceptedStream?,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> SendStart {
    guard call == TarwinCall.endpointSend, flags & ~3 == 0 else { return .unsupported }
    guard permitted, caller.exit == nil else { return .denied }
    guard !sources.isEmpty, sources.count <= maxVectors else { return .invalid }
    var n = 0
    for b in sources {
      guard b.count <= Int.max - n, b.isEmpty || b.baseAddress != nil else { return .invalid }
      n += b.count
    }
    return StreamGrant.acquire(
      caller: caller, name: name, port: port, key: key, rights: 8, ports: &ports, resolve: resolve,
      supports: { n == 0 || $0.connection.outputLimit > 0 }, retire: retire
    ) { (g: consuming StreamGrant) in EndpointSend(sources, n, flags, consume g) }
  }
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    grant.matches(port: port, operation: operation)
  }
  /// Serve the oldest pending send first. The caller serializes stream state,
  /// rechecks the process and egress grant, and drives TCP after submission.
  public mutating func poll<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, permitted: Bool,
    releasePins: () -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> SendProgress {
    guard grant.active else { return .inactive }
    let stream = grant.stream
    let state = stream.connection.state
    let error: UInt32
    if !permitted {
      error = 4
    } else if state == .timedOut {
      error = 25
    } else if state == .reset {
      error = 61
    } else if state != .established && state != .closeWait {
      error = 27
    } else {
      error = 0
    }
    let n = error == 0 ? min(count, stream.connection.outputRoom) : 0
    if error == 0 && count > 0 && n == 0 { return .waiting }
    var prefix: [UInt8] = []
    prefix.reserveCapacity(n)
    for b in sources {
      let remaining = n - prefix.count
      if remaining == 0 { break }
      prefix.append(contentsOf: b.prefix(remaining))
    }
    let flags = self.flags
    grant.finish(at: now, ports: &ports, releasePins: releasePins, retire: retire) {
      var p = PortPacket()
      if error != 0 {
        p.error = error
        p.subsystem = 6
      } else {
        stream.connection.enqueueOutput(prefix, flags: flags, at: now)
        p.result0 = UInt64(n)
      }
      return p
    }
    return .finished
  }
  @discardableResult public mutating func withdraw<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P,
    releasePins: () -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    grant.withdraw(at: now, ports: &ports, releasePins: releasePins, retire: retire)
  }
}
