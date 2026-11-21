import TarwinSyscall

public struct ExitRecord {
  public let reason: GuestExit
  public let address: UInt64
  public let width: UInt64
  public let write: Bool
  public let data: UInt64
  public let registerIndex: UInt64

  public init(
    reason: GuestExit, address: UInt64, width: UInt64, write: Bool, data: UInt64,
    registerIndex: UInt64
  ) {
    self.reason = reason
    self.address = address
    self.width = width
    self.write = write
    self.data = data
    self.registerIndex = registerIndex
  }
}
public func canceledExit() -> ExitRecord {
  return ExitRecord(
    reason: .canceled, address: 0, width: 0, write: false, data: 0, registerIndex: 0)
}
// The control path pins the vCPU throughout. Each state access (arm, finish,
// request) takes its lock separately; no exclusive Swift access spans guest
// execution. The platform's armed-entry/kick handshake must not lose a kick.
public func runCpu(
  _ number: UInt64, thread: UInt64, arm: (UInt64) -> RunAction,
  enter: () -> ExitRecord, finish: (GuestExit) -> GuestExit
) -> Result<ExitRecord, HvError> {
  guard number == TarwinCall.virtualCpuRun else { return .failure(.invalid) }
  switch arm(thread) {
  case .deny: return .failure(.wrongThread)
  case .busy: return .failure(.busy)
  case .cancel: return .success(canceledExit())
  case .enter: break
  }
  let record = enter()
  return .success(finish(record.reason) == .canceled ? canceledExit() : record)
}

public func interruptRun(_ number: UInt64, request: () -> Bool, kick: () -> Void) -> Bool {
  guard number == TarwinCall.virtualCpuRequestExit else { return false }
  if request() { kick() }
  return true
}

public func changeMapping(
  _ number: UInt64, _ extent: inout GuestExtent, _ guest: UInt64,
  _ offset: UInt64, _ length: UInt64, _ guestLimit: UInt64, _ objectSize: UInt64,
  _ page: UInt64, _ permissions: UInt64, _ rights: UInt64, _ pin: (UInt64, UInt64) -> UInt64,
  _ install: (UInt64, UInt64, UInt64, UInt64) -> Bool, _ unpin: (UInt64) -> Void,
  _ detach: (UInt64, UInt64) -> Bool, _ flush: (UInt64, UInt64) -> Bool
) -> Bool {
  if number == TarwinCall.virtualMachineMap {
    return extent.map(
      guest, offset, length, guestLimit, objectSize, page, permissions, rights, pin, install, unpin)
  }
  if number == TarwinCall.virtualMachineUnmap && guest == extent.start && length == extent.size {
    return extent.retire(detach, flush, unpin)
  }
  return false
}
