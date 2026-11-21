import TarwinArchHosted
import TarwinSched

/// Map a scheduler-owned dispatch key; exhausted deadline budgets demote normally.
public func hostedSchedulingPolicy(_ key: DispatchKey, periodNanos: UInt64 = 0) -> HostSchedulingPolicy {
  switch key.effective() {
  case SchedClass.deadline:
    return .realtime(periodNanos: periodNanos, computationNanos: key.remainingBudget)
  case SchedClass.interactive, SchedClass.initiated: return .interactive
  case SchedClass.background, SchedClass.idle: return .background
  default: return .default
  }
}

/// Apply on every scheduler class/budget transition, not on each gate call.
public func applyHostedSchedulingChange(_ key: DispatchKey, to thread: HostThread, periodNanos: UInt64 = 0) throws {
  try thread.apply(hostedSchedulingPolicy(key, periodNanos: periodNanos))
}
