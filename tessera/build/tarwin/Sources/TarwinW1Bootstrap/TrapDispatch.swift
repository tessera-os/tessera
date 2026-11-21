import TarwinArchAarch64
import TarwinSyscall

/// Called by the VHE lower-EL synchronous vector's private dispatcher.
/// Get the active process and its *exact mapped and verified library code*
/// from kernel per-CPU state. Frame and scratch are disjoint, kernel-only;
/// retain the current context on this CPU until the vector restores it.
/// Only resumeEL0 can pass the return gate; an accepted exit selects the
/// stop continuation. Neither stop nor exception paths restore this frame.
@unsafe public func dispatchPrivateW1Trap<P: CallProvider>(
  frame: UnsafeMutableRawBufferPointer, libraryCode: Range<UInt64>, userRange: Range<UInt64>,
  scratch: UnsafeMutableBufferPointer<UInt64>, provider: inout P
) -> Arm64TrapOutcome {
  guard frame.count == ArmTrapLayout.size, let start = frame.baseAddress,
    UInt(bitPattern: start) & 15 == 0, !libraryCode.isEmpty,
    libraryCode.lowerBound >= 1 << 32, libraryCode.upperBound <= 1 << 43,
    !userRange.isEmpty, userRange.lowerBound >= 1 << 32, userRange.upperBound <= 1 << 47
  else { return .invalidKernelFrame }
  let bank = UnsafeMutableBufferPointer(
    start: start.assumingMemoryBound(to: UInt64.self), count: 31)
  return dispatchArm64EL0(
    esr: frame.load(fromByteOffset: ArmTrapLayout.esr, as: UInt64.self),
    spsr: frame.load(fromByteOffset: ArmTrapLayout.spsr, as: UInt64.self),
    elr: frame.load(fromByteOffset: ArmTrapLayout.elr, as: UInt64.self),
    gprs: bank, libraryCode: libraryCode, userRange: userRange, scratch: scratch,
    provider: &provider)
}
