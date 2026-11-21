public enum SleepMode { case suspendToIdle, connectedStandby }
public enum SleepExit: Equatable {
  case wake(WakeCause)
  case armingFailed, deviceRefused, platformReturned
}
public enum SuspendResult: Equatable {
  case busy, recovering
  case finished(SleepExit)
}
public enum SleepAdmission: Equatable {
  case blocked, busy
  case admitted(UInt64)
}

/// One controller per power plane. Serialize changes of locks/topology with
/// admission: a change after admission must wake the gate or wait for recovery.
public struct SystemSleep: ~Copyable {
  private let gate: UnsafePointer<WakeGate>
  private var devices: SleepTransaction, generation: UInt64?, outcome: SleepExit?, mode: SleepMode?
  public init?(nodes: Int, dependencies: [PowerEdge], gate: UnsafePointer<WakeGate>) {
    guard case .order(let order) = planSuspend(nodes, dependencies) else { return nil }
    devices = SleepTransaction(order: order)
    self.gate = gate
  }
  /// Hold the policy and topology admission lock for this short section
  /// only. Publish the token to policy-change producers before unlocking.
  public mutating func admit(_ mode: SleepMode, locks: borrowing WakeLocks) -> SleepAdmission {
    guard generation == nil else { return .busy }
    guard !locks.preventsSleep(.system) else { return .blocked }
    guard let token = gate.pointee.arm() else { return .busy }
    generation = token
    self.mode = mode
    return .admitted(token)
  }
  /// Arm sources before powering down the first device. The platform idle
  /// primitive must check gate.armed(token) as part of parking, paired with
  /// the producer's persistent kick. A plain check followed by WFI is unsafe.
  public mutating func suspend(
    _ token: UInt64,
    arm: (SleepMode, UInt64) -> Bool, sleep: (Int) -> Bool,
    park: (SleepMode, UInt64) -> Void, resume: (Int) -> Bool, disarmAndDrain: (UInt64) -> Bool
  ) -> SuspendResult {
    guard generation == token, let mode, outcome == nil else { return .busy }
    if !arm(mode, token) {
      outcome = .armingFailed
    } else if !devices.quiesce(sleep, { !gate.pointee.armed(token) }, resume) {
      outcome = gate.pointee.cause(token).map(SleepExit.wake) ?? .deviceRefused
      if devices.asleep != 0 { return .recovering }
    } else {
      if gate.pointee.armed(token) { park(mode, token) }
      outcome = gate.pointee.cause(token).map(SleepExit.wake) ?? .platformReturned
    }
    return recover(resume: resume, disarmAndDrain: disarmAndDrain)
  }
  /// Retry only the unavailable provider or undrained wake sources. No
  /// second sleep is admitted and no already restored dependent is replayed.
  public mutating func recover(resume: (Int) -> Bool, disarmAndDrain: (UInt64) -> Bool)
    -> SuspendResult
  {
    guard let token = generation, let outcome else { return .busy }
    guard devices.restore(resume), disarmAndDrain(token) else { return .recovering }
    gate.pointee.retire(token)
    generation = nil
    mode = nil
    self.outcome = nil
    return .finished(outcome)
  }
}
