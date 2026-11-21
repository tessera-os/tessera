// A stream is allocated by the host listener and bound to one VM, guest port and
// allowed local endpoint. The caller serializes its two queues; 32-bit credit
// counters wrap, but an update cannot acknowledge more bytes than were sent.
public enum SocketPhase { case listen, connected, closed }
public enum SocketAction { case reject, accept, delivered, credit, sendCredit, peerShutdown, reset }
public struct GuestSocket {
  public let guestCid: UInt64
  public let guestPort: UInt64
  public let hostPort: UInt64
  public let receiveLimit: UInt64
  public internal(set) var phase: SocketPhase = .listen
  public internal(set) var peerShut: UInt64 = 0
  public internal(set) var outstanding: UInt64 = 0
  public internal(set) var peerForward: UInt64 = 0
  public internal(set) var peerCapacity: UInt64 = 0
  public internal(set) var inUse: UInt64 = 0
  public internal(set) var forwarded: UInt64 = 0

  public init(guestCid: UInt64, guestPort: UInt64, hostPort: UInt64, receiveLimit: UInt64) {
    self.guestCid = guestCid
    self.guestPort = guestPort
    self.hostPort = hostPort
    self.receiveLimit = receiveLimit
  }

  public mutating func receive(_ command: [UInt8], _ deliver: ([UInt8]) -> Bool) -> SocketAction {
    if phase == .closed || command.count < 44 || UInt64(command.count) > DeviceIoLimit.bytes
      || guestCid < 3 || guestCid >= 0xffff_ffff || receiveLimit > 0xffff_ffff
      || vword(command, 0, 8) != guestCid || vword(command, 8, 8) != 2
      || vword(command, 16, 4) != guestPort || vword(command, 20, 4) != hostPort
      || vword(command, 28, 2) != 1
    {
      return .reject
    }
    let size = vword(command, 24, 4)
    let op = vword(command, 30, 2)
    let flags = vword(command, 32, 4)
    let credit = vword(command, 36, 4)
    let fwd = vword(command, 40, 4)
    let advance = (0x1_0000_0000 + fwd - peerForward) & 0xffff_ffff
    if size != UInt64(command.count - 44) || (op != 5 && size != 0)
      || advance > outstanding || (op != 4 && flags != 0) || flags > 3
    {
      return .reject
    }
    var action = SocketAction.reject
    switch op {
    case 1:
      if phase != .listen { return .reject }
      phase = .connected
      action = .accept

    case 3:
      phase = .closed
      action = .reset
    case 4:
      if phase != .connected || flags == 0 { return .reject }
      peerShut = peerShut | flags
      action = .peerShutdown

    case 5:
      if phase != .connected || (peerShut & 2) != 0 || size > receiveLimit - inUse {
        return .reject
      }
      var payload: [UInt8] = []
      for i in 44..<command.count { payload.append(command[i]) }
      if !deliver(payload) { return .reject }
      inUse += size
      action = .delivered

    case 6, 7:
      if phase != .connected { return .reject }
      action = op == 6 ? .credit : .sendCredit

    default: return .reject
    }
    outstanding -= advance
    peerForward = fwd
    peerCapacity = credit
    return action
  }
  public mutating func reserveSend(_ size: UInt64) -> Bool {
    if phase != .connected || (peerShut & 1) != 0 || outstanding > peerCapacity
      || size > peerCapacity - outstanding
    {
      return false
    }
    outstanding += size
    return true
  }
  public mutating func consumed(_ bytes: UInt64) -> Bool {
    if bytes > inUse { return false }
    inUse -= bytes
    forwarded = (forwarded + bytes) & 0xffff_ffff
    return true
  }
}
