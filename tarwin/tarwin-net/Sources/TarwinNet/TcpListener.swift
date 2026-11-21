struct TcpPeerSyn {
  let sequence: UInt32, window: UInt16, mss: UInt16?, scale: UInt8?, timestamp: UInt32?, sack: Bool
  init(_ p: TcpSegment) {
    sequence = p.sequence
    window = p.window
    mss = p.options.mss
    scale = p.options.scale
    timestamp = p.options.timestamp
    sack = p.options.sackPermitted
  }
  func reply(path: TcpPath, sequence local: UInt32, capacity: Int, stamp: UInt32?) -> [UInt8] {
    path.encode(
      local, sequence &+ 1, 18, UInt32(min(capacity, 65535)),
      tcpSynOptions(
        path, sack: sack, shift: scale == nil ? nil : tcpWindowShift(capacity),
        timestamp: timestamp == nil ? nil : stamp, echo: timestamp ?? 0), [])
  }
}
private struct HalfOpen {
  let path: TcpPath, peer: TcpPeerSyn, sequence: UInt32, offset: UInt32?, expires: UInt64
  var retryAt: UInt64, rto: UInt64 = 1_000_000_000, sent = false
  func response(_ capacity: Int, now: UInt64) -> [UInt8] {
    let ts = offset.map { $0 &+ UInt32(truncatingIfNeeded: now / 1_000_000) }
    return peer.reply(path: path, sequence: sequence, capacity: capacity, stamp: ts)
  }
}
public enum TcpListenInput: ~Copyable {
  case ignored, pending, full
  case established(TcpConnection)
}

/// A half-open backlog for a single reserved local address, port, interface
/// and epoch. Serialize with established-connection demux and accept queues.
public struct TcpListener: ~Copyable {
  private let local: [UInt8], port: UInt16, interface: UInt64, epoch: UInt64, limit: Int,
    capacity: Int
  private var entries: [HalfOpen] = [], clock: UInt64 = 0, closed = false
  public var pending: Int { entries.count }
  public init?(
    serverEntitled: Bool, local: [UInt8], port: UInt16, interface: UInt64, epoch: UInt64,
    backlog: Int, receiveBytes: Int
  ) {
    guard serverEntitled, local.count == 4 || local.count == 16, port != 0, interface != 0,
      epoch != 0,
      (1...1024).contains(backlog), (1...1_048_576).contains(receiveBytes)
    else { return nil }
    self.local = local
    self.port = port
    self.interface = interface
    self.epoch = epoch
    limit = backlog
    capacity = receiveBytes
    entries.reserveCapacity(backlog)
  }
  public mutating func close() {
    closed = true
    entries.removeAll()
  }
  private mutating func advance(_ now: UInt64) -> Bool {
    guard !closed, now >= clock else { return false }
    clock = now
    entries.removeAll { $0.expires <= now }
    return true
  }
  private mutating func reply(_ i: Int, now: UInt64, emit: (TcpPath, [UInt8]) -> Bool) {
    let e = entries[i]
    if emit(e.path, e.response(capacity, now: now)) {
      if e.sent { entries[i].rto = min(16_000_000_000, e.rto * 2) }
      entries[i].sent = true
      entries[i].retryAt = tcpLater(now, entries[i].rto)
    }
  }
  /// The route provider excludes reserved/established tuples. Generate fresh
  /// unpredictable ISS and (if offered) timestamp offsets only on admission.
  /// Egress authorization and pacing are mandatory inside emit, even on retries.
  public mutating func input(
    _ p: TcpSegment, path: TcpPath, interface: UInt64, epoch: UInt64,
    at now: UInt64, permit: (TcpSegment) -> Bool, initial: () -> (UInt32, UInt32?),
    canPromote: () -> Bool, emit: (TcpPath, [UInt8]) -> Bool
  ) -> TcpListenInput {
    guard interface == self.interface, epoch == self.epoch, path.local == local,
      path.localPort == port,
      path.matches(p), permit(p), advance(now)
    else { return .ignored }
    if let i = entries.firstIndex(where: {
      $0.path.remote == path.remote && $0.path.remotePort == path.remotePort
    }) {
      let e = entries[i]
      guard path == e.path else { return .ignored }
      if p.flags & 4 != 0 {
        if e.sent, p.sequence == e.peer.sequence &+ 1, p.flags & 16 == 0 || p.ack == e.sequence &+ 1
        {
          entries.remove(at: i)
        }
        return .ignored
      }
      if p.flags & 0x3f == 2, p.sequence == e.peer.sequence, p.payload.isEmpty {
        if e.retryAt <= now { reply(i, now: now, emit: emit) }
        return .pending
      }
      guard e.sent, p.flags & 0x36 == 16, p.ack == e.sequence &+ 1,
        p.sequence == e.peer.sequence &+ 1,
        p.payload.count + (p.flags & 1 != 0 ? 1 : 0) <= min(capacity, 65535)
      else { return .ignored }
      if e.offset != nil {
        guard let ts = p.options.timestamp, let previous = e.peer.timestamp,
          Int32(bitPattern: ts &- previous) >= 0
        else { return .ignored }
      }
      guard canPromote() else { return .full }
      guard
        var c = TcpConnection(
          accepted: path, localNext: p.ack, peer: e.peer, capacity: capacity,
          timestampOffset: e.offset, now: now), c.input(p, at: now, admit: { _ in true })
      else { return .ignored }
      entries.remove(at: i)
      return .established(c)
    }
    guard p.flags & 0x3f == 2, p.payload.isEmpty else { return .ignored }
    guard entries.count < limit else { return .full }
    let (iss, ts) = initial()
    entries.append(
      HalfOpen(
        path: path, peer: TcpPeerSyn(p), sequence: iss,
        offset: p.options.timestamp == nil ? nil : ts, expires: tcpLater(now, 60_000_000_000),
        retryAt: now))
    reply(entries.count - 1, now: now, emit: emit)
    return .pending
  }
  /// Call on timer and writable notifications. Half-opens expire even when
  /// TX cannot publish. The caller closes this listener on interface removal.
  public mutating func pump(at now: UInt64, emit: (TcpPath, [UInt8]) -> Bool) {
    guard advance(now) else { return }
    for i in entries.indices where entries[i].retryAt <= now { reply(i, now: now, emit: emit) }
  }
}
