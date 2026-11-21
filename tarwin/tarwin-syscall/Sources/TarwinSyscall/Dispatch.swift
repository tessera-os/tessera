import TarwinABI

/// The composition layer supplies only registered handlers. A handler must
/// enforce its authority checks before operating on any kernel object.
public protocol CallProvider {
  func argumentCount(for number: UInt64) -> UInt32?
  /// Must use the platform's fault-recoverable unprivileged copy. Never
  /// construct a Swift pointer directly from the user's integer address.
  mutating func copyUserWords(
    from address: UInt64, into destination: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool
  mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult
}

public enum DispatchResult {
  case terminateBadOrigin  // TARWIN-S0001; the trap path must not resume this process.
  case returned(CallResult)
}

/// Gate metadata and scratch are private to this entry. Pass the executable
/// LibTessera mapping, not a span that includes other images or data.
public func dispatchCall<P: CallProvider>(
  isa: CallISA, savedPC: UInt64, libraryCode: Range<UInt64>,
  userRange: Range<UInt64>, number: UInt64, registers: CallRegisters,
  scratch: UnsafeMutableBufferPointer<UInt64>, provider: inout P
) -> DispatchResult {
  guard let ip = isa.instruction(savedPC: savedPC),
    syscallOriginAllowed(ip, isa.instructionWidth, libraryCode.lowerBound, libraryCode.upperBound)
  else { return .terminateBadOrigin }
  guard TarwinCall.isAssigned(number), let slots = provider.argumentCount(for: number) else {
    return .returned(CallResult(status: syscallStatus(10, 1)))
  }
  let n = Int(slots)
  let capacity = isa.argumentCount
  guard n <= scratch.count else { return .returned(CallResult(status: syscallStatus(90, 1))) }
  let count = n > capacity ? capacity - 1 : n
  for i in 0..<count { scratch[i] = registers[i] }
  if count != n {
    let address = registers[count]
    let bytes = syscallTailBytes(slots, UInt32(capacity))
    guard syscallTailInRange(address, bytes, userRange.lowerBound, userRange.upperBound),
      provider.copyUserWords(
        from: address, into: UnsafeMutableBufferPointer(rebasing: scratch[count..<n]))
    else { return .returned(CallResult(status: syscallStatus(1, 1))) }
  }
  return .returned(
    provider.invoke(
      number: number, words: UnsafeBufferPointer(rebasing: UnsafeBufferPointer(scratch)[..<n])))
}
