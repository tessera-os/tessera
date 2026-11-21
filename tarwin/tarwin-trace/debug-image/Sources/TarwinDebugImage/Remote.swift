// Debug-image-only, polled GDB RSP. ASCII inspection packets need no binary
// escape decoding. Unknown commands receive an empty reply. The platform owns
// the bounded scratch page, verified debug boot state and exclusive transport.
public enum RxState { case idle, data, checkHigh, checkLow }
public enum RxAction { case more, ack, reject, packet }
func nibble(_ b: UInt8) -> UInt64 {
  if b >= 48 && b <= 57 { return UInt64(b) - 48 }
  if b >= 97 && b <= 102 { return UInt64(b) - 87 }
  if b >= 65 && b <= 70 { return UInt64(b) - 55 }
  return 16
}
func digit(_ n: UInt64) -> UInt8 { return UInt8(n < 10 ? n + 48 : n + 87) }
public struct PacketReader {
  public internal(set) var state: RxState = .idle
  public internal(set) var length: UInt64 = 0
  public internal(set) var checksum: UInt64 = 0
  public internal(set) var high: UInt64 = 0

  public init() {}

  public mutating func receive(_ b: UInt8, _ save: (UInt64, UInt8) -> Void) -> RxAction {
    if b == 36 {
      length = 0
      checksum = 0
      state = .data
      return .more
    }
    switch state {
    case .idle: return b == 43 ? .ack : .more
    case .data:
      if b == 35 {
        state = .checkHigh
        return .more
      }
      if length >= 4096 {
        state = .idle
        return .reject
      }
      save(length, b)
      length += 1
      checksum = (checksum + UInt64(b)) & 255

    case .checkHigh:
      high = nibble(b)
      if high > 15 {
        state = .idle
        return .reject
      }
      state = .checkLow

    case .checkLow:
      state = .idle
      let low = nibble(b)
      if low < 16 && high * 16 + low == checksum { return .packet }
      return .reject
    }
    return .more
  }
}
public struct RemoteStop {
  public internal(set) var stopped: Bool = false

  public init() {}

  // Stop-all either captures every CPU or rolls back, before publishing any state.
  public mutating func connect(
    _ verifiedDebug: Bool, _ exclusiveTransport: Bool, _ stopAll: () -> Bool
  ) -> Bool {
    if stopped || !verifiedDebug || !exclusiveTransport { return false }
    stopped = stopAll()
    return stopped
  }
  public mutating func disconnect(_ resumeAll: () -> Void) {
    if stopped {
      stopped = false
      resumeAll()
    }
  }
}
public struct Reply {
  public internal(set) var sum: UInt64 = 0

  public init() {}

  public mutating func byte(_ b: UInt8, _ send: (UInt8) -> Void) {
    sum = (sum + UInt64(b)) & 255
    send(b)
  }
  public mutating func hex(_ b: UInt8, _ send: (UInt8) -> Void) {
    byte(digit(UInt64(b) >> 4), send)
    byte(digit(UInt64(b) & 15), send)
  }
  public func finish(_ send: (UInt8) -> Void) {
    send(35)
    send(digit(sum >> 4))
    send(digit(sum & 15))
  }
}

// getRegisterByte exposes only the captured architecture register set in GDB's
// target byte order. No write or arbitrary live-memory accessor exists here.
public func replyStopped(
  _ session: RemoteStop, _ n: UInt64, _ get: (UInt64) -> UInt8, _ registerBytes: UInt64,
  _ getRegisterByte: (UInt64) -> UInt8, _ send: (UInt8) -> Void
) -> Bool {
  if !session.stopped || n == 0 || n > 4096 { return false }
  var out = Reply()
  send(36)
  let cmd = get(0)
  if cmd == 63 && n == 1 {
    out.byte(83, send)
    out.byte(48, send)
    out.byte(53, send)
  } else if cmd == 103 && n == 1 {
    if registerBytes == 0 || registerBytes > 2048 {
      out.byte(69, send)
      out.byte(48, send)
      out.byte(49, send)
    } else {
      var index: UInt64 = 0
      while index < registerBytes {
        out.hex(getRegisterByte(index), send)
        index += 1
      }
    }
  } else if cmd == 68 && n == 1 {
    out.byte(79, send)
    out.byte(75, send)
  }
  out.finish(send)
  return cmd == 68 && n == 1
}
