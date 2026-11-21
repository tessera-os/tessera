/// An established route is supplied by the network policy/route owner. It
/// reserves the source port and prevents reuse of a live or TIME-WAIT tuple.
public struct TcpPath {
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
  fileprivate var ip: Int { local.count == 4 ? 20 : 40 }
  fileprivate var mss: Int { mtu - ip - 20 }
  fileprivate func matches(_ p: TcpSegment) -> Bool {
    p.source == remote && p.destination == local && p.sourcePort == remotePort
      && p.destinationPort == localPort
  }
  /// The caller has already bounded data and options to the path MTU.
  fileprivate func encode(
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
private func later(_ now: UInt64, _ delay: UInt64) -> UInt64 {
  now > UInt64.max - delay ? .max : now + delay
}

public enum TcpState: Equatable {
  case idle, synSent, established, closeWait, finWait1, finWait2, closing, lastAck, timeWait,
    closed, reset, timedOut
}
private struct Flight {
  var sequence: UInt32, data: [UInt8], flags: UInt8, deadline: UInt64, first: UInt64,
    retries: Int = 0
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
  public init?(path: TcpPath, initialSequence: UInt32, receiveBytes: Int, retries: Int = 5) {
    guard (1...65535).contains(receiveBytes), (1...12).contains(retries),
      let window = TcpReceiveWindow(next: 0, capacity: receiveBytes, sackNegotiated: false)
    else { return nil }
    self.path = path
    next = initialSequence
    una = initialSequence
    capacity = receiveBytes
    retryLimit = retries
    rx = window
  }
  public var readable: Int { state == .reset || state == .timedOut ? 0 : rx.readable }
  public var endOfInput: Bool { rx.atEnd }
  public var unacknowledged: UInt32 { next &- una }
  /// Policy revocation or interface removal cancels the connection locally.
  public mutating func abort() {
    flight = nil
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
      let m = path.mss
      return path.encode(
        seq, 0, 2, UInt32(capacity), [2, 4, UInt8(m >> 8), UInt8(truncatingIfNeeded: m), 4, 2], [])
    }
    let ack = rx.acknowledgement
    let room = min(40, path.mss - data.count)
    return path.encode(seq, ack.next, flags, ack.window, ack.sackOption(available: room & ~3), data)
  }
  private mutating func start(
    _ flags: UInt8, _ bytes: [UInt8], _ now: UInt64, _ emit: ([UInt8]) -> Bool
  ) -> Bool {
    guard flight == nil, emit(packet(next, flags, bytes)) else { return false }
    flight = Flight(
      sequence: next, data: bytes, flags: flags, deadline: later(now, rto), first: now)
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
    guard state == .established || state == .closeWait, flight == nil, stamp(now) else { return 0 }
    let n = min(peerWindow, peerMss, path.mss, bytes.count)
    guard n > 0, start(0x18, Array(bytes.prefix(n)), now, emit) else { return 0 }
    return n
  }
  public mutating func finish(at now: UInt64, emit: ([UInt8]) -> Bool) -> Bool {
    guard state == .established || state == .closeWait, peerWindow > 0, stamp(now),
      start(17, [], now, emit)
    else { return false }
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
    expires = later(now, 120_000_000_000)
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
          next: p.sequence &+ 1, capacity: capacity, sackNegotiated: p.options.sackPermitted)
      else { return false }
      rx = w
      peerMss = Int(p.options.mss ?? (path.ip == 20 ? 536 : 1220))
      peerWindow = Int(p.window)
      if f.retries == 0 { sample(now - f.first) } else { rto = max(rto, 3_000_000_000) }
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
    if advance > Int(unacknowledged) || advance < -65535 {
      ackPending = true
      return true
    }
    if advance >= 0, delta(p.sequence, wl1) > 0 || (p.sequence == wl1 && delta(p.ack, wl2) >= 0) {
      peerWindow = Int(p.window)
      wl1 = p.sequence
      wl2 = p.ack
    }
    if advance > 0, var f = flight {
      una = p.ack
      if una == next {
        if f.retries == 0 { sample(now - f.first) }
        flight = nil
        if f.flags & 1 != 0 {
          if state == .finWait1 {
            state = .finWait2
          } else if state == .closing {
            timeWait(now)
          } else if state == .lastAck {
            state = .closed
            ackPending = false
            return true
          }
        }
      } else {
        f.data.removeFirst(advance)
        f.sequence = una
        f.deadline = later(now, rto)
        flight = f
      }
    }
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
  /// Called at incoming events, writable-device notifications and timer expiry.
  /// Egress policy, pacing and challenge-ACK rate limiting precede publication.
  @discardableResult public mutating func pump(at now: UInt64, emit: ([UInt8]) -> Bool) -> Bool {
    guard stamp(now) else { return false }
    if state == .timeWait, now >= expires {
      state = .closed
      ackPending = false
    }
    if var f = flight, now >= f.deadline {
      if f.retries >= retryLimit {
        abort()
        state = .timedOut
        return false
      }
      guard emit(packet(f.sequence, f.flags, f.data)) else { return false }
      f.retries += 1
      rto = min(60_000_000_000, rto * 2)
      f.deadline = later(now, rto)
      flight = f
      ackPending = false
      return true
    }
    guard ackPending, emit(packet(next, 16, [])) else { return false }
    ackPending = false
    return true
  }
}
