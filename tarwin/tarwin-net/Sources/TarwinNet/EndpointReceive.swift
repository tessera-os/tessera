import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

public typealias ReceiveStart = StreamStart<EndpointReceive>
public enum ReceiveProgress { case waiting, finished, inactive }

/// A worker serves the head of a submitted stream receive queue. Keep the
/// submitting process, its writable VM pins and the stream registry alive.
/// The resolver may only look up the payload of the retained Endpoint.
public struct EndpointReceive: ~Copyable {
  private var grant: StreamGrant
  private let buffers: [UnsafeMutableRawBufferPointer], count: Int, flags: UInt32
  private init(
    _ buffers: [UnsafeMutableRawBufferPointer], _ count: Int, _ flags: UInt32,
    _ grant: consuming StreamGrant
  ) {
    self.grant = consume grant
    self.buffers = buffers
    self.count = count
    self.flags = flags
  }
  /// A validated kernel snapshot of the iovecs, never pointers from the call
  /// frame. maxVectors is the trusted submission limit, not an ABI argument.
  public static func begin<P: IoPorts & ~Copyable>(
    call: UInt64, caller: borrowing ProcessExecution, name: UInt64, port: UInt64, key: UInt64,
    flags: UInt32, buffers: [UnsafeMutableRawBufferPointer], maxVectors: Int,
    ports: inout P, permitted: Bool, resolve: (UnsafePointer<ObjectHeader>) -> TcpAcceptedStream?,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ReceiveStart {
    guard call == TarwinCall.endpointReceive, flags & ~3 == 0 else { return .unsupported }
    guard permitted, caller.exit == nil else { return .denied }
    guard !buffers.isEmpty, buffers.count <= maxVectors else { return .invalid }
    var length = 0
    for b in buffers {
      guard b.count <= Int.max - length, b.isEmpty || b.baseAddress != nil else { return .invalid }
      length += b.count
    }
    guard length > 0 else { return .invalid }  // reserve a zero count for orderly EOF
    return StreamGrant.acquire(
      caller: caller, name: name, port: port, key: key, rights: 4, ports: &ports,
      resolve: resolve, supports: { flags & 2 == 0 || length <= $0.connection.inputLimit },
      retire: retire
    ) {
      (g: consuming StreamGrant) in EndpointReceive(buffers, length, flags, consume g)
    }
  }

  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    grant.matches(port: port, operation: operation)
  }

  /// Under the stream worker lock. Check the process and network grant again;
  /// bytes are committed and consumed only if the exact port credit is live.
  public mutating func poll<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, permitted: Bool,
    releasePins: () -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ReceiveProgress {
    guard grant.active else { return .inactive }
    let s = grant.stream
    let state = s.connection.state
    let available = s.connection.readable
    if permitted && state != .reset && state != .timedOut && !s.connection.inputFinished {
      if available == 0 || (flags & 2 != 0 && available < count) { return .waiting }
    }
    let dest = buffers
    let peek = flags & 1 != 0
    let limit = count
    grant.finish(at: now, ports: &ports, releasePins: releasePins, retire: retire) {
      var p = PortPacket()
      if !permitted {
        p.error = 4
      } else if state == .reset {
        p.error = 61
      } else if state == .timedOut {
        p.error = 25
      } else {
        var index = 0
        var offset = 0
        func scatter(_ bytes: ArraySlice<UInt8>) {
          bytes.withUnsafeBytes { source in
            var i = 0
            while i < source.count {
              while offset == dest[index].count {
                index += 1
                offset = 0
              }
              let n = min(source.count - i, dest[index].count - offset)
              dest[index].baseAddress!.advanced(by: offset).copyMemory(
                from: source.baseAddress!.advanced(by: i), byteCount: n)
              offset += n
              i += n
            }
          }
        }
        let n =
          peek
          ? s.connection.peek(upTo: limit, copy: scatter)
          : s.connection.read(upTo: limit) {
            scatter($0)
            return true
          }
        p.result0 = UInt64(n)
      }
      if p.error != 0 { p.subsystem = 6 }
      return p
    }
    return .finished
  }

  /// Called on the exact operation scheduled by cancellation or port close.
  /// No access to the stream or user destinations is needed to withdraw it.
  @discardableResult public mutating func withdraw<P: IoPorts & ~Copyable>(
    at now: UInt64,
    ports: inout P, releasePins: () -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    grant.withdraw(at: now, ports: &ports, releasePins: releasePins, retire: retire)
  }
}
