public enum ServiceState {
  case waiting
  case serving
  case replied
  case timedOut
  case peerClosed
  case cancelled
}

// Owned by the service's transaction table, never shared with users. The
// table holds the channel's lock across each transition. Only its winner
// completes the caller and releases any donated scheduling context.
public struct ServiceCall {
  public let transaction: UInt64
  public let deadline: UInt64
  public let context: UInt64
  public internal(set) var server: UInt64
  public internal(set) var state: ServiceState

  public func live() -> Bool { return state == .waiting || state == .serving }

  public mutating func expire(_ now: UInt64) -> Bool {
    if !live() || deadline == 0xffff_ffff_ffff_ffff || now < deadline { return false }
    state = .timedOut
    return true
  }

  public mutating func receive(_ worker: UInt64, _ now: UInt64) -> Bool {
    if state != .waiting || worker == 0 || expire(now) { return false }
    server = worker
    state = .serving
    return true
  }

  public mutating func reply(_ txid: UInt64, _ worker: UInt64, _ now: UInt64) -> Bool {
    if state != .serving || transaction != txid || server != worker || expire(now) { return false }
    state = .replied
    return true
  }

  public mutating func cancel(_ peerDied: Bool) -> Bool {
    if !live() { return false }
    if peerDied { state = .peerClosed } else { state = .cancelled }
    return true
  }

  public func donatedTo(_ worker: UInt64) -> UInt64 {
    if state == .serving && server == worker { return context }
    return 0
  }

  public init(
    transaction: UInt64, deadline: UInt64, context: UInt64, server: UInt64, state: ServiceState
  ) {
    self.transaction = transaction
    self.deadline = deadline
    self.context = context
    self.server = server
    self.state = state
  }
}

public func inlineCall(_ bytes: UInt32, _ handles: UInt32) -> Bool {
  return bytes <= 128 && handles <= 4
}

public func channelMessageFits(_ bytes: UInt64, _ handles: UInt64) -> Bool {
  return bytes <= 65536 && handles <= 64
}
