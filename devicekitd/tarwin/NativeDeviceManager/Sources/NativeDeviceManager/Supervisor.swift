import NativeDriverKit

public enum DriverState: Equatable {
  case discovered
  case starting
  case running
  case quiescing
  case backoff
  case failed
  case removed
}

public struct DriverSupervisor: Equatable {
  public let apiYear: UInt32
  public let apiMonth: UInt32
  public let pingInterval: UInt64
  public internal(set) var state: DriverState = .discovered
  public internal(set) var failures: [UInt64] = []
  public internal(set) var retained: Int = 0
  public internal(set) var epoch: UInt64 = 0
  public internal(set) var resumeAt: UInt64 = 0
  public internal(set) var pingAt: UInt64 = 0
  public internal(set) var unanswered: UInt32 = 0
  public internal(set) var gone: Bool = false
  public internal(set) var exhausted: Bool = false

  public mutating func start(
    _ now: UInt64, _ trainYear: UInt32, _ trainMonth: UInt32, _ launch: (UInt64) -> Bool
  ) -> Bool {
    if state != .discovered && state != .backoff { return false }
    if gone || now < resumeAt || epoch == 0xffff_ffff_ffff_ffff || pingInterval == 0
      || !compatibleDriver(trainYear, trainMonth, apiYear, apiMonth)
    {
      return false
    }
    epoch += 1
    state = .starting
    if !launch(epoch) {
      _ = failed(now, epoch, false)
      return false
    }
    return true
  }

  public mutating func ready(_ now: UInt64, _ generation: UInt64) -> Bool {
    if state != .starting || generation != epoch { return false }
    unanswered = 0
    pingAt = now
    state = .running
    return true
  }

  public mutating func pong(_ generation: UInt64, _ challenge: UInt64) -> Bool {
    if state != .running || epoch != generation || unanswered == 0 || challenge != pingAt {
      return false
    }
    unanswered = 0
    return true
  }

  public mutating func watchdog(_ now: UInt64, _ sendPing: (UInt64, UInt64) -> Void) {
    if state != .running || now < pingAt || now - pingAt < pingInterval { return }
    if unanswered == 2 {
      _ = failed(now, epoch, false)
      return
    }
    unanswered += 1
    pingAt = now
    sendPing(epoch, now)
  }

  // Sliding ten-minute budget. Five failures disable this personality,
  // not the kernel objects its clients hold. Old epochs cannot affect it.
  public mutating func failed(_ now: UInt64, _ generation: UInt64, _ removed: Bool) -> Bool {
    if (state != .running && state != .starting) || generation != epoch { return false }
    gone = removed
    state = .quiescing
    if removed { return true }
    var keep: Int = 0
    for i in 0..<retained {
      let time = failures[i]
      if now < time || now - time < 600_000_000_000 {
        failures[keep] = time
        keep += 1
      }
    }
    if keep == failures.count { failures.append(now) } else { failures[keep] = now }
    retained = keep + 1
    exhausted = retained >= 5
    var delay: UInt64 = 0
    if retained == 2 { delay = 100_000_000 }
    if retained == 3 { delay = 1_000_000_000 }
    if retained >= 4 { delay = 10_000_000_000 }
    resumeAt = delay > 0xffff_ffff_ffff_ffff - now ? 0xffff_ffff_ffff_ffff : now + delay
    return true
  }

  // The manager's removal path can run even while waiting for reset.
  public mutating func remove() {
    gone = true
    if state == .backoff || state == .discovered || state == .failed {
      state = .removed
    } else if state != .removed {
      state = .quiescing
    }
  }

  public mutating func quiesce(_ revokeAndDrain: (UInt64, Bool) -> Bool) -> Bool {
    if state != .quiescing || !revokeAndDrain(epoch, gone) { return false }
    if gone { state = .removed } else if exhausted { state = .failed } else { state = .backoff }
    return true
  }

  public init(apiYear: UInt32, apiMonth: UInt32, pingInterval: UInt64) {
    self.apiYear = apiYear
    self.apiMonth = apiMonth
    self.pingInterval = pingInterval
  }
}
