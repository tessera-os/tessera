import TarwinSyscall

// After entry checks and typed handle pinning, under the VM control lock.
// The architecture provider performs an atomic armed-entry/kick handshake. It
// cannot sleep holding the lock. 'enter' must return with the lock reacquired.
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
public func runCpu(
  _ number: UInt64, _ cpu: inout VirtualCpuState, _ thread: UInt64,
  _ enter: () -> ExitRecord
) -> Result<ExitRecord, HvError> {
  if number != TarwinCall.virtualCpuRun { return .failure(.invalid) }
  switch cpu.begin(thread) {
  case .deny: return .failure(.wrongThread)
  case .busy: return .failure(.busy)
  case .cancel: return .success(canceledExit())
  case .enter: break
  }
  let record = enter()
  if cpu.finish(record.reason) == GuestExit.canceled { return .success(canceledExit()) }
  return .success(record)
}
public func interruptRun(_ number: UInt64, _ cpu: inout VirtualCpuState, _ kick: () -> Void) -> Bool
{
  if number != TarwinCall.virtualCpuRequestExit { return false }
  if cpu.requestExit() { kick() }
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
