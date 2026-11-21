/// An established route is supplied by the network policy/route owner. It
/// reserves the source port and prevents reuse of a live or TIME-WAIT tuple.
public struct TcpPath: Equatable {
  public let local: [UInt8], remote: [UInt8], localPort: UInt16, remotePort: UInt16, mtu: Int,
    hops: UInt8
  public init?(
    local: [UInt8], remote: [UInt8], localPort: UInt16, remotePort: UInt16, mtu: Int,
    hops: UInt8 = 64
  ) {
    func unicast(_ ip: [UInt8]) -> Bool {
      ip.count == 4
        ? ip[0] > 0 && ip[0] < 224 : ip.count == 16 && ip[0] != 255 && ip.contains { $0 != 0 }
    }
    guard local.count == remote.count, unicast(local), unicast(remote), localPort > 0,
      remotePort > 0,
      mtu >= (local.count == 4 ? 68 : 1280), mtu <= 65535, hops > 0
    else { return nil }
    self.local = local
    self.remote = remote
    self.localPort = localPort
    self.remotePort = remotePort
    self.mtu = mtu
    self.hops = hops
  }
  var ip: Int { local.count == 4 ? 20 : 40 }
  var mss: Int { mtu - ip - 20 }
  func matches(_ p: TcpSegment) -> Bool {
    p.source == remote && p.destination == local && p.sourcePort == remotePort
      && p.destinationPort == localPort
  }
  /// The caller has already bounded data and options to the path MTU.
  func encode(
    _ seq: UInt32, _ ack: UInt32, _ flags: UInt8, _ win: UInt32, _ options: [UInt8], _ data: [UInt8]
  ) -> [UInt8] {
    let opt = (options.count + 3) & ~3
    let header = 20 + opt
    let tcp = header + data.count
    var b = [UInt8](repeating: 0, count: ip + header)
    let addr: Int
    if ip == 20 {
      addr = 12
      b[0] = 0x45
      putWord(&b, 2, UInt32(ip + tcp))
      b[6] = 0x40
      b[8] = hops
      b[9] = 6
    } else {
      addr = 8
      b[0] = 0x60
      putWord(&b, 4, UInt32(tcp))
      b[6] = 6
      b[7] = hops
    }
    b.replaceSubrange(addr..<addr + local.count, with: local)
    b.replaceSubrange(addr + local.count..<addr + 2 * local.count, with: remote)
    if ip == 20 { putWord(&b, 10, 0xffff ^ sumBytes(b, 0, 20, 0)) }
    putWord(&b, ip, UInt32(localPort))
    putWord(&b, ip + 2, UInt32(remotePort))
    putWord(&b, ip + 4, seq >> 16)
    putWord(&b, ip + 6, seq)
    putWord(&b, ip + 8, ack >> 16)
    putWord(&b, ip + 10, ack)
    b[ip + 12] = UInt8(header / 4) << 4
    b[ip + 13] = flags
    putWord(&b, ip + 14, win)
    b.replaceSubrange(ip + 20..<ip + 20 + options.count, with: options)
    b.append(contentsOf: data)
    let pseudo = sumBytes(b, addr, local.count * 2, 0) + UInt32(tcp) + 6
    putWord(&b, ip + 16, 0xffff ^ sumBytes(b, ip, tcp, (pseudo & 0xffff) + (pseudo >> 16)))
    return b
  }
}
private func delta(_ a: UInt32, _ b: UInt32) -> Int { Int(Int32(bitPattern: a &- b)) }
func tcpLater(_ now: UInt64, _ delay: UInt64) -> UInt64 {
  now > UInt64.max - delay ? .max : now + delay
}
func tcpWindowShift(_ bytes: Int) -> UInt8 {
  var shift: UInt8 = 0
  while (65535 << shift) < bytes { shift += 1 }
  return shift
}
func tcpTimestamp(_ stamp: UInt32?, echo: UInt32) -> [UInt8] {
  guard let stamp else { return [] }
  var opt: [UInt8] = [1, 1, 8, 10]
  for v in [stamp, echo] {
    for shift in [24, 16, 8, 0] { opt.append(UInt8(truncatingIfNeeded: v >> shift)) }
  }
  return opt
}
func tcpSynOptions(_ path: TcpPath, sack: Bool, shift: UInt8?, timestamp: UInt32?, echo: UInt32)
  -> [UInt8]
{
  var opts: [UInt8] = [2, 4, UInt8(path.mss >> 8), UInt8(truncatingIfNeeded: path.mss)]
  if sack { opts += [4, 2] }
  if let shift { opts += [3, 3, shift] }
  return opts + tcpTimestamp(timestamp, echo: echo)
}

public enum TcpState: Equatable {
  case idle, synSent, established, closeWait, finWait1, finWait2, closing, lastAck, timeWait,
    closed, reset, timedOut
}
private struct Flight {
  var sequence: UInt32, data: [UInt8], flags: UInt8, deadline: UInt64, first: UInt64,
    retries: Int = 0
  var lastSent: UInt64, stamp: UInt32?
  var probed = false
}
private enum DeferredSend {
  case byte(UInt8)
  case fin
  var flags: UInt8 {
    if case .fin = self { return 17 }
    return 0x18
  }
  var data: [UInt8] {
    if case .byte(let b) = self { return [b] }
    return []
  }
}
private struct PersistTimer {
  var deadline: UInt64, interval: UInt64, unanswered = 0
}
/// Conservative active opener: one unacknowledged segment. Serialize on
/// one lock; callbacks never reenter. The caller authorizes the interface
/// and epoch at ingress and on *every* egress, including retransmissions.
/// Supply an unpredictable kernel-generated ISS and a monotonic clock in ns.
public struct TcpConnection: ~Copyable {
  public private(set) var state: TcpState = .idle
  public let path: TcpPath
  private let capacity: Int, retryLimit: Int
  private var next: UInt32, una: UInt32, wl1: UInt32 = 0, wl2: UInt32 = 0, peerWindow = 0,
    peerMss = 0
  private var rx: TcpReceiveWindow, flight: Flight?, ackPending = false, clock: UInt64 = 0,
    expires: UInt64 = 0
  private var rto: UInt64 = 1_000_000_000, srtt: UInt64?, rttvar: UInt64 = 0
  private var deferred: DeferredSend?, persist: PersistTimer?
  private var output: ArraySlice<UInt8> = [], corkUntil: UInt64?
  private let timestampOffset: UInt32?, offeredShift: UInt8
  private var recent: UInt32?, recentAt: UInt64 = 0, lastAckSent: UInt32 = 0
  private var sendShift: UInt8 = 0, receiveShift: UInt8 = 0, maxPeerWindow = 0
  /// Supply a private per-connection timestamp offset to offer timestamps.
  public init?(
    path: TcpPath, initialSequence: UInt32, receiveBytes: Int, retries: Int = 5,
    timestampOffset: UInt32? = nil
  ) {
    guard (1...1_048_576).contains(receiveBytes), (1...12).contains(retries),
      let window = TcpReceiveWindow(next: 0, capacity: receiveBytes, sackNegotiated: false)
    else { return nil }
    self.path = path
    next = initialSequence
    una = initialSequence
    capacity = receiveBytes
    retryLimit = retries
    self.timestampOffset = timestampOffset
    offeredShift = tcpWindowShift(receiveBytes)
    rx = window
  }
  // Called only after the bounded listener validates the third handshake
  // segment. No full-sized receive buffer is allocated for the initial SYN.
  init?(
    accepted path: TcpPath, localNext: UInt32, peer: TcpPeerSyn, capacity: Int,
    timestampOffset: UInt32?, now: UInt64
  ) {
    guard
      let window = TcpReceiveWindow(
        next: peer.sequence &+ 1,
        capacity: peer.scale == nil ? min(65535, capacity) : capacity, sackNegotiated: peer.sack)
    else { return nil }
    self.path = path
    self.capacity = capacity
    self.timestampOffset = timestampOffset
    retryLimit = 5
    offeredShift = tcpWindowShift(capacity)
    rx = window
    una = localNext
    next = localNext
    lastAckSent = peer.sequence &+ 1
    wl1 = peer.sequence
    wl2 = localNext
    peerMss = Int(peer.mss ?? (path.ip == 20 ? 536 : 1220))
    peerWindow = Int(peer.window)
    maxPeerWindow = peerWindow
    if let s = peer.scale {
      sendShift = s
      receiveShift = offeredShift
    }
    recent = timestampOffset == nil ? nil : peer.timestamp
    recentAt = now
    state = .established
    clock = now
  }
  public var readable: Int { state == .reset || state == .timedOut ? 0 : rx.readable }
  public var endOfInput: Bool { rx.atEnd }
  var inputFinished: Bool { rx.finished }
  var inputLimit: Int { rx.capacity }
  func peek(upTo: Int, copy: (ArraySlice<UInt8>) -> Void) -> Int {
    guard state != .reset, state != .timedOut else { return 0 }
    return rx.peek(upTo: upTo, copy: copy)
  }
  public var unacknowledged: UInt32 { next &- una }
  /// Policy revocation or interface removal cancels the connection locally.
  public mutating func abort() {
    output = []
    corkUntil = nil
    flight = nil
    deferred = nil
    persist = nil
    ackPending = false
    una = next
    state = .reset
  }
  private mutating func stamp(_ now: UInt64) -> Bool {
    guard now >= clock else { return false }
    clock = now
    return true
  }
  private func packet(_ seq: UInt32, _ flags: UInt8, _ data: [UInt8]) -> [UInt8] {
    if flags == 2 {
      return path.encode(
        seq, 0, 2, UInt32(min(65535, capacity)),
        tcpSynOptions(path, sack: true, shift: offeredShift, timestamp: localTimestamp, echo: 0), []
      )
    }
    let ack = rx.acknowledgement
    let ts = recent.map { tcpTimestamp(localTimestamp, echo: $0) } ?? []
    let room = min(40, (data.isEmpty ? path.mss : min(peerMss, path.mss)) - data.count)
    let opts = ts + ack.sackOption(available: (room & ~3) - ts.count)
    return path.encode(seq, ack.next, flags, min(65535, ack.window >> receiveShift), opts, data)
  }
  private var localTimestamp: UInt32? {
    timestampOffset.map { $0 &+ UInt32(truncatingIfNeeded: clock / 1_000_000) }
  }
  private mutating func publish(
    _ seq: UInt32, _ flags: UInt8, _ bytes: [UInt8], _ emit: ([UInt8]) -> Bool
  ) -> Bool {
    guard emit(packet(seq, flags, bytes)) else { return false }
    if flags & 16 != 0 { lastAckSent = rx.acknowledgement.next }
    return true
  }
  private mutating func start(
    _ flags: UInt8, _ bytes: [UInt8], _ now: UInt64, _ emit: ([UInt8]) -> Bool
  ) -> Bool {
    guard flight == nil, publish(next, flags, bytes, emit) else { return false }
    flight = Flight(
      sequence: next, data: bytes, flags: flags, deadline: tcpLater(now, rto), first: now,
      lastSent: now, stamp: localTimestamp)
    next = next &+ UInt32(bytes.count + (flags & 3 != 0 ? 1 : 0))
    ackPending = false
    return true
  }
  public mutating func connect(at now: UInt64, emit: ([UInt8]) -> Bool) -> Bool {
    guard state == .idle, stamp(now), start(2, [], now, emit) else { return false }
    state = .synSent
    return true
  }
  /// Return the accepted prefix length. It is retained until cumulatively ACKed.
  public mutating func write(_ bytes: ArraySlice<UInt8>, at now: UInt64, emit: ([UInt8]) -> Bool)
    -> Int
  {
    guard output.isEmpty, state == .established || state == .closeWait, flight == nil,
      deferred == nil, stamp(now)
    else { return 0 }
    let payload = min(peerMss, path.mss) - (recent == nil ? 0 : 12)
    if peerWindow == 0, payload > 0, let byte = bytes.first {
      deferred = .byte(byte)
      updatePersist(now)
      return 1
    }
    let n = min(peerWindow, payload, bytes.count)
    guard n > 0, start(0x18, Array(bytes.prefix(n)), now, emit) else { return 0 }
    return n
  }
  public mutating func finish(at now: UInt64, emit: ([UInt8]) -> Bool) -> Bool {
    if !output.isEmpty {
      corkUntil = nil
      return false
    }
    guard state == .established || state == .closeWait, flight == nil, deferred == nil, stamp(now)
    else { return false }
    if peerWindow == 0 {
      deferred = .fin
      updatePersist(now)
    } else if !start(17, [], now, emit) {
      return false
    }
    state = state == .established ? .finWait1 : .lastAck
    return true
  }
  public mutating func read(upTo: Int, copy: (ArraySlice<UInt8>) -> Bool) -> Int {
    guard state != .reset, state != .timedOut else { return 0 }
    let n = rx.read(upTo: upTo, copy: copy)
    if n > 0 && !rx.acknowledgement.finished { ackPending = true }
    return n
  }
  private mutating func sample(_ elapsed: UInt64) {
    let r = min(elapsed, 60_000_000_000)
    if let s = srtt {
      rttvar = (3 * rttvar + (r > s ? r - s : s - r)) / 4
      srtt = (7 * s + r) / 8
    } else {
      srtt = r
      rttvar = r / 2
    }
    rto = min(60_000_000_000, max(1_000_000_000, srtt! + max(1_000_000, 4 * rttvar)))
  }
  private mutating func timeWait(_ now: UInt64) {
    state = .timeWait
    expires = tcpLater(now, 120_000_000_000)
  }
  private mutating func acknowledged(_ f: Flight, _ echo: UInt32?, _ now: UInt64) {
    guard !f.probed else { return }
    if recent != nil {
      if let stamp = f.stamp, echo == stamp, now - f.first < 2_073_600_000_000_000 {
        sample(now - f.lastSent)
      }
    } else if f.retries == 0 {
      sample(now - f.first)
    }
  }
  /// Process one already checksum-validated segment. ACK output is scheduled
  /// through pump; a full transmit ring never loses the obligation to ACK.
  public mutating func input(_ p: TcpSegment, at now: UInt64, admit: (TcpSegment) -> Bool) -> Bool {
    guard path.matches(p), state != .idle, state != .closed, state != .timedOut, state != .reset,
      admit(p), stamp(now)
    else { return false }
    if state == .synSent {
      guard p.flags & 16 != 0, p.ack == next else { return false }
      if p.flags & 4 != 0 {
        abort()
        return true
      }
      guard p.flags & 0x37 == 0x12, p.payload.isEmpty, let f = flight,
        let w = TcpReceiveWindow(
          next: p.sequence &+ 1, capacity: p.options.scale == nil ? min(capacity, 65535) : capacity,
          sackNegotiated: p.options.sackPermitted)
      else { return false }
      rx = w
      peerMss = Int(p.options.mss ?? (path.ip == 20 ? 536 : 1220))
      peerWindow = Int(p.window)
      maxPeerWindow = peerWindow
      if let shift = p.options.scale {
        receiveShift = offeredShift
        sendShift = shift
      }
      if timestampOffset != nil {
        recent = p.options.timestamp
        recentAt = now
      }
      lastAckSent = p.sequence
      acknowledged(f, p.options.timestampEcho, now)
      if f.retries > 0 { rto = max(rto, 3_000_000_000) }
      una = next
      wl1 = p.sequence
      wl2 = p.ack
      flight = nil
      state = .established
      ackPending = true
      return true
    }
    let rc = rx.acknowledgement
    let offset = delta(p.sequence, rc.next)
    let len = p.payload.count + (p.flags & 1 != 0 ? 1 : 0) + (p.flags & 2 != 0 ? 1 : 0)
    if let last = recent, p.flags & 4 == 0 {
      // Negotiated TSopt is mandatory on non-RST segments; a missing one
      // is silently discarded. PAWS rejects are ACKed without moving state.
      guard let timestamp = p.options.timestamp else { return true }
      if delta(timestamp, last) < 0, now - recentAt < 2_073_600_000_000_000 {
        ackPending = true
        return true
      }
    }
    if state == .timeWait {
      if p.flags & 0x17 == 17, p.sequence &+ UInt32(len) == rc.next {
        timeWait(now)
        ackPending = true
      }
      return true
    }
    let acceptable =
      len == 0
      ? offset == 0 || (offset > 0 && offset < Int(rc.window))
      : rc.window > 0 && offset < Int(rc.window) && offset + len > 0
    if !acceptable {
      if p.flags & 4 == 0 { ackPending = true }
      return true
    }
    if p.flags & 4 != 0 {
      if offset == 0 {
        abort()
      } else {
        ackPending = true
      }
      return true
    }
    if p.flags & 2 != 0 {
      ackPending = true
      return true
    }
    guard p.flags & 0x30 == 0x10 else { return false }
    let advance = delta(p.ack, una)
    if advance > Int(unacknowledged) || advance < -maxPeerWindow {
      ackPending = true
      return true
    }
    if advance >= 0, delta(p.sequence, wl1) > 0 || (p.sequence == wl1 && delta(p.ack, wl2) >= 0) {
      peerWindow = Int(p.window) << sendShift
      persist?.unanswered = 0
      maxPeerWindow = max(maxPeerWindow, peerWindow)
      wl1 = p.sequence
      wl2 = p.ack
    }
    if recent != nil, let stamp = p.options.timestamp, delta(p.sequence, lastAckSent) <= 0 {
      recent = stamp
      recentAt = now
    }
    if advance > 0, var f = flight {
      una = p.ack
      if una == next {
        acknowledged(f, p.options.timestampEcho, now)
        flight = nil
        if f.flags & 1 != 0 {
          if state == .finWait1 {
            state = .finWait2
          } else if state == .closing {
            timeWait(now)
          } else if state == .lastAck {
            state = .closed
            persist = nil
            ackPending = false
            return true
          }
        }
      } else {
        f.data.removeFirst(advance)
        f.sequence = una
        f.deadline = tcpLater(now, rto)
        flight = f
      }
    }
    updatePersist(now)
    if len > 0 {
      _ = rx.receive(p) { _ in true }
      ackPending = true
      if rx.acknowledgement.finished {
        if state == .established {
          state = .closeWait
        } else if state == .finWait1 {
          state = .closing
        } else if state == .finWait2 {
          timeWait(now)
        }
      }
    }
    return true
  }
  // Keep the timer independent of loss recovery. A responsive receiver may
  // keep its window closed indefinitely. Its replies do not restart the clock.
  private mutating func updatePersist(_ now: UInt64) {
    if peerWindow == 0 && (flight != nil || deferred != nil) {
      if persist == nil { persist = PersistTimer(deadline: tcpLater(now, rto), interval: rto) }
    } else {
      if persist != nil, peerWindow > 0, flight?.probed == true {
        flight?.deadline = now
        flight?.retries = 0
      }
      persist = nil
    }
  }
  private mutating func sendDeferred(_ now: UInt64, _ emit: ([UInt8]) -> Bool) -> Bool {
    guard let d = deferred, start(d.flags, d.data, now, emit) else { return false }
    deferred = nil
    return true
  }
  var outputLimit: Int { max(0, min(peerMss, path.mss) - (recent == nil ? 0 : 12)) }
  var outputRoom: Int {
    // Once publication starts, drain this backing store before extending it.
    output.startIndex == 0 ? max(0, outputLimit - output.count) : 0
  }
  /// Called only at send commit under the stream lock. No transport callback
  /// runs while the client's completion port is locked.
  mutating func enqueueOutput(_ bytes: [UInt8], flags: UInt32, at now: UInt64) {
    precondition(bytes.count <= outputRoom)
    if bytes.isEmpty { return }
    let fresh = output.isEmpty
    output.append(contentsOf: bytes)
    if flags & 2 == 0 || flags & 1 != 0 || output.count == outputLimit {
      corkUntil = nil
    } else if fresh {
      corkUntil = tcpLater(now, 200_000_000)
    }
  }
  private mutating func consumeOutput(_ count: Int) {
    output.removeFirst(count)
    if output.isEmpty { output = [] }
    corkUntil = nil
  }
  /// Called at incoming events, writable-device notifications and timer expiry.
  /// Egress policy, pacing and challenge-ACK rate limiting precede publication.
  @discardableResult public mutating func pump(at now: UInt64, emit: ([UInt8]) -> Bool) -> Bool {
    guard stamp(now) else { return false }
    if state == .timeWait, now >= expires {
      state = .closed
      ackPending = false
    }
    if var timer = persist, now >= timer.deadline {
      if timer.unanswered >= retryLimit {
        abort()
        state = .timedOut
        return false
      }
      if let f = flight {
        // Never resend an entire old flight through a newly closed window.
        guard publish(f.sequence, f.flags, Array(f.data.prefix(1)), emit) else { return false }
      } else if !sendDeferred(now, emit) {
        return false
      }
      flight?.probed = true
      ackPending = false
      timer.interval = min(60_000_000_000, timer.interval * 2)
      timer.deadline = tcpLater(now, timer.interval)
      timer.unanswered += 1
      persist = timer
      return true
    }
    if peerWindow > 0, deferred != nil { return sendDeferred(now, emit) }
    if persist == nil, var f = flight, now >= f.deadline {
      if f.retries >= retryLimit {
        abort()
        state = .timedOut
        return false
      }
      guard publish(f.sequence, f.flags, f.data, emit) else { return false }
      let stamp = localTimestamp
      f.stamp = stamp == f.stamp ? nil : stamp
      f.lastSent = now
      f.retries += 1
      rto = min(60_000_000_000, rto * 2)
      f.deadline = tcpLater(now, rto)
      flight = f
      ackPending = false
      return true
    }
    if flight == nil, deferred == nil, let first = output.first, now >= (corkUntil ?? 0) {
      if peerWindow == 0 {
        deferred = .byte(first)
        consumeOutput(1)
        updatePersist(now)
      } else {
        let n = min(peerWindow, output.count)
        guard start(0x18, Array(output.prefix(n)), now, emit) else { return false }
        consumeOutput(n)
        return true
      }
    }
    guard ackPending, publish(next, 16, [], emit) else { return false }
    ackPending = false
    return true
  }
}
