import TarwinIPC
import TarwinIoCompletion
import TarwinObject
import TarwinSyscall

private struct DatagramDestination {
  let buffers: NetScatter, source: UnsafeMutableRawBufferPointer?
  func copy(_ message: UdpMessage, interface: UInt32) -> (bytes: UInt64, flags: UInt64) {
    var dest = buffers
    let n = min(dest.capacity, message.bytes.count)
    dest.copy(message.bytes.prefix(n))
    if let source {
      storePeer(message.source, port: message.sourcePort, interface: interface, to: source)
    }
    return (UInt64(n), n < message.bytes.count ? 1 : 0)
  }
}
func storeNetScalar(
  _ value: UInt64, bytes: Int, at offset: Int, in record: UnsafeMutableRawBufferPointer
) {
  for i in 0..<bytes { record[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
}

/// WaitAll never joins datagrams. Peek retains every message, even on truncation.
public struct DatagramReceive: ~Copyable {
  private enum Targets {
    case one(DatagramDestination)
    case many([DatagramDestination], UnsafeMutableRawBufferPointer)
  }
  private var grant: EndpointGrant<UdpMailbox>
  private let targets: Targets, peek: Bool
  private init(_ grant: consuming EndpointGrant<UdpMailbox>, _ targets: Targets, _ peek: Bool) {
    self.grant = consume grant
    self.targets = targets
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
      DatagramReceive(
        consume g, .one(DatagramDestination(buffers: dest, source: source)), flags & 1 != 0)
    }
  }
  /// The submitter snapshots all descriptors and pins all destinations first.
  /// records is the exact writable array of 56-byte LibTessera Datagrams.
  /// Never reload a pointer/count from it, including while writing results.
  public static func beginMany<P: IoPorts & ~Copyable>(
    call: UInt64, caller: borrowing ProcessExecution, name: UInt64, port: UInt64, key: UInt64,
    flags: UInt32, buffers: [[UnsafeMutableRawBufferPointer]],
    records: UnsafeMutableRawBufferPointer,
    maxMessages: Int, maxVectors: Int, ports: inout P, permitted: Bool,
    resolve: (UnsafePointer<ObjectHeader>) -> UdpMailbox?,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> EndpointIoStart<DatagramReceive> {
    guard call == TarwinCall.endpointReceiveMany, flags & ~3 == 0 else { return .unsupported }
    guard caller.exit == nil, permitted else { return .denied }
    guard !buffers.isEmpty, buffers.count <= maxMessages, buffers.count <= Int.max / 56,
      records.count == buffers.count * 56, records.baseAddress != nil
    else { return .invalid }
    var targets: [DatagramDestination] = []
    var left = maxVectors
    for (i, v) in buffers.enumerated() {
      guard let dest = NetScatter(v, limit: left) else { return .invalid }
      left -= v.count
      targets.append(
        DatagramDestination(
          buffers: dest, source: .init(rebasing: records[(56 * i + 16)..<(56 * i + 48)])))
    }
    return EndpointGrant.acquire(
      caller: caller, name: name, port: port, key: key, rights: 4, ports: &ports,
      resolve: resolve, supports: { _ in true }, retire: retire
    ) { (g: consuming EndpointGrant<UdpMailbox>) in
      DatagramReceive(consume g, .many(targets, records), flags & 1 != 0)
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
    let targets = self.targets
    let peek = self.peek
    grant.finish(at: now, ports: &ports, releasePins: releasePins, retire: retire) {
      var packet = PortPacket()
      guard permitted, !mailbox.closed else {
        packet.error = permitted ? 23 : 4
        packet.subsystem = 6
        return packet
      }
      switch targets {
      case .one(let target):
        let message = mailbox.message(at: 0)
        (packet.result0, packet.aux) = target.copy(message, interface: mailbox.interface)
        packet.result1 = mailbox.receiveTimestamps ? message.receivedAt : 0
        if !peek { mailbox.dequeue() }
      case .many(let dest, let records):
        let n = min(dest.count, mailbox.count)
        for i in 0..<n {
          let result = dest[i].copy(mailbox.message(at: peek ? i : 0), interface: mailbox.interface)
          storeNetScalar(result.bytes, bytes: 8, at: i * 56 + 48, in: records)
          storeNetScalar(result.flags, bytes: 4, at: i * 56 + 12, in: records)
          if !peek { mailbox.dequeue() }
        }
        packet.result0 = UInt64(n)
      }
      return packet
    }
    return .finished
  }
  @discardableResult public mutating func withdraw<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, releasePins: () -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool { grant.withdraw(at: now, ports: &ports, releasePins: releasePins, retire: retire) }
}
