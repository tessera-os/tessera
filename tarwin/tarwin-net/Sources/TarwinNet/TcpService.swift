/// Stream payload shared with the kernel Endpoint object's registry. Serialize
/// all access with the network worker, including transfer out of the backlog.
public final class TcpAcceptedStream {
  public var connection: TcpConnection
  fileprivate init(_ c: consuming TcpConnection) { connection = consume c }
}
public enum TcpServiceInput { case ignored, pending, full, ready, delivered }

/// Completed handshakes stay in FIFO order, and continue to receive data
/// while waiting for an accept. A reset remains observable by its acceptor.
public struct TcpService: ~Copyable {
  public let koid: UInt64, interface: UInt32, epoch: UInt64
  public private(set) var closed = false
  private var listener: TcpListener, queue: [TcpAcceptedStream] = []
  private let limit: Int
  public var ready: Int { queue.count }
  public init?(
    koid: UInt64, serverEntitled: Bool, local: [UInt8], port: UInt16, interface: UInt32,
    epoch: UInt64, backlog: Int, receiveBytes: Int, bufferBudget: Int
  ) {
    // Bound full stream storage across all pending accepts, not just per SYN.
    guard koid != 0, receiveBytes > 0, bufferBudget >= 0, backlog <= bufferBudget / receiveBytes,
      let l = TcpListener(
        serverEntitled: serverEntitled, local: local, port: port,
        interface: UInt64(interface), epoch: epoch, backlog: backlog, receiveBytes: receiveBytes)
    else { return nil }
    self.koid = koid
    self.interface = interface
    self.epoch = epoch
    limit = backlog
    listener = l
    queue.reserveCapacity(backlog)
  }
  public mutating func close() {
    closed = true
    listener.close()
    for s in queue { s.connection.abort() }
    queue.removeAll()
  }
  public mutating func input(
    _ p: TcpSegment, path: TcpPath, interface: UInt32, epoch: UInt64, at now: UInt64,
    permit: (TcpSegment) -> Bool, initial: () -> (UInt32, UInt32?), emit: (TcpPath, [UInt8]) -> Bool
  ) -> TcpServiceInput {
    guard !closed, interface == self.interface, epoch == self.epoch, path.matches(p), permit(p)
    else { return .ignored }
    if let s = queue.first(where: { $0.connection.path.matches(p) }) {
      return s.connection.input(p, at: now, admit: { _ in true }) ? .delivered : .ignored
    }
    let room = queue.count < limit
    switch listener.input(
      p, path: path, interface: UInt64(interface), epoch: epoch, at: now,
      permit: { _ in true }, initial: initial, canPromote: { room }, emit: emit)
    {
    case .ignored: return .ignored
    case .pending: return .pending
    case .full: return .full
    case .established(let connection):
      queue.append(TcpAcceptedStream(consume connection))
      return .ready
    }
  }
  public mutating func pump(at now: UInt64, emit: (TcpPath, [UInt8]) -> Bool) {
    listener.pump(at: now, emit: emit)
    for s in queue {
      let path = s.connection.path
      _ = s.connection.pump(at: now) { emit(path, $0) }
    }
  }
  /// The worker may prepare its kernel object before taking the port lock.
  public var nextForAccept: TcpAcceptedStream? { queue.first }
  mutating func dequeue() { queue.removeFirst() }
}
