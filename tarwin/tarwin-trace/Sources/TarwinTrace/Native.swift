import TarwinSyscall

public func createCounters(
  _ call: UInt64, _ scope: CounterScope, _ target: UInt64, _ targetOwner: UInt64,
  _ caller: UInt64, _ debugResource: Bool
) -> CounterSession? {
  if call != TarwinCall.performanceSessionCreate
    || !counterAccess(scope, targetOwner, caller, debugResource)
    || (scope != .system && target == 0)
  {
    return .none
  }
  return .some(CounterSession(target: target))
}

// Takes a pinned session with the operation-specific rights already checked.
// A PMU token's read returns its count since program(), not a destructive read.
public func useCounters(
  _ call: UInt64, _ session: inout CounterSession,
  _ program: (UInt64) -> UInt64, _ read: (UInt64) -> UInt64,
  _ stopAndRelease: (UInt64) -> UInt64
) -> UInt64? {
  if call == TarwinCall.performanceSessionStart {
    if !session.start(program) { return .none }
    return .some(0)
  }
  if call == TarwinCall.performanceSessionStop {
    if !session.stop(stopAndRelease) { return .none }
    return .some(0)
  }
  if call != TarwinCall.performanceSessionRead { return .none }
  let delta = session.hardware == 0 ? UInt64(0) : read(session.hardware)
  return .some(
    delta > 0xffff_ffff_ffff_ffff - session.total
      ? UInt64(0xffff_ffff_ffff_ffff) : session.total + delta)
}
