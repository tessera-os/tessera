import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

/// One completion corresponds to one datagram, including a zero-byte one.
/// WaitAll never joins datagrams; Peek retains the entire head, even on truncation.
public struct DatagramReceive: ~Copyable {
  private var grant: EndpointGrant<UdpMailbox>
  private let buffers: NetScatter, source: UnsafeMutableRawBufferPointer?, peek: Bool
  private init(
    _ grant: consuming EndpointGrant<UdpMailbox>, _ buffers: NetScatter,
    _ source: UnsafeMutableRawBufferPointer?, _ peek: Bool
  ) {
    self.grant = consume grant
    self.buffers = buffers
    self.source = source
    self.peek = peek
  }
  public static func begin<P: IoPorts & ~Copyable>(
    call: UInt64, caller: borrowing ProcessExecution, name: UInt64, port: UInt64, key: UInt64,
    flags: UInt32, buffers: [UnsafeMutableRawBufferPointer], source: UnsafeMutableRawBufferPointer?,
    maxVectors: Int, ports: inout P, permitted: Bool,
    resolve: (UnsafePointer<ObjectHeader>) -> UdpMailbox?,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> EndpointIoStart<DatagramReceive> {
    guard call == TarwinCall.endpointReceive || call == TarwinCall.endpointReceiveFrom,
      flags & ~3 == 0
    else { return .unsupported }
    guard caller.exit == nil, permitted else { return .denied }
    guard let dest = NetScatter(buffers, limit: maxVectors),
      call == TarwinCall.endpointReceiveFrom
        ? (source?.count == 32 && source?.baseAddress != nil) : source == nil
    else { return .invalid }
    return EndpointGrant.acquire(
      caller: caller, name: name, port: port, key: key, rights: 4, ports: &ports,
      resolve: resolve, supports: { _ in true }, retire: retire
    ) { (g: consuming EndpointGrant<UdpMailbox>) in
      DatagramReceive(consume g, dest, source, flags & 1 != 0)
    }
  }
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    grant.matches(port: port, operation: operation)
  }
  public mutating func poll<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, permitted: Bool, releasePins: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ReceiveProgress {
    guard grant.active else { return .inactive }
    let mailbox = grant.payload
    guard !permitted || mailbox.closed || mailbox.count != 0 else { return .waiting }
    var dest = buffers
    let source = self.source
    let peek = self.peek
    grant.finish(at: now, ports: &ports, releasePins: releasePins, retire: retire) {
      var packet = PortPacket()
      guard permitted, !mailbox.closed, let message = mailbox.first else {
        packet.error = permitted ? 23 : 4
        packet.subsystem = 6
        return packet
      }
      let n = min(dest.capacity, message.bytes.count)
      dest.copy(message.bytes.prefix(n))
      if let source {
        storePeer(
          message.source, port: message.sourcePort, interface: mailbox.interface, to: source)
      }
      packet.result0 = UInt64(n)
      packet.result1 = mailbox.receiveTimestamps ? message.receivedAt : 0
      packet.aux = n < message.bytes.count ? 1 : 0
      if !peek { mailbox.dequeue() }
      return packet
    }
    return .finished
  }
  @discardableResult public mutating func withdraw<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, releasePins: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool { grant.withdraw(at: now, ports: &ports, releasePins: releasePins, retire: retire) }
}
