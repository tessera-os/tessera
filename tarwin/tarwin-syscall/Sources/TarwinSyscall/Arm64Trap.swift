import TarwinABI

public enum Arm64TrapOutcome {
  case resumeEL0, terminateBadOrigin, otherSynchronousException, invalidKernelFrame
}

/// Called only by the lower-EL synchronous vector, on a private kernel
/// stack. All control registers and the 31 GPRs are hardware-saved or
/// captured by that vector. Other banks, SP, ELR and SPSR are never edited.
/// The RX range belongs to the verified LibTessera in the current process.
public func dispatchArm64EL0<P: CallProvider>(
  esr: UInt64, spsr: UInt64, elr: UInt64,
  gprs: UnsafeMutableBufferPointer<UInt64>, libraryCode: Range<UInt64>, userRange: Range<UInt64>,
  scratch: UnsafeMutableBufferPointer<UInt64>, provider: inout P
) -> Arm64TrapOutcome {
  guard gprs.count == 31 else { return .invalidKernelFrame }
  guard spsr & 31 == 0, (esr >> 26) & 63 == 0x15 else { return .otherSynchronousException }
  // Nonzero SVC immediates are not part of the ABI. They cannot exempt
  // user code from the same instruction-origin policy.
  if esr & 0xffff != 0 || esr & (1 << 25) == 0 {
    return callOriginAllowed(isa: .aarch64, savedPC: elr, libraryCode: libraryCode)
      ? .otherSynchronousException : .terminateBadOrigin
  }
  let regs = CallRegisters(gprs[0], gprs[1], gprs[2], gprs[3], gprs[4], gprs[5], gprs[6], gprs[7])
  switch dispatchCall(
    isa: .aarch64, savedPC: elr, libraryCode: libraryCode, userRange: userRange,
    number: gprs[16], registers: regs, scratch: scratch, provider: &provider)
  {
  case .terminateBadOrigin: return .terminateBadOrigin
  case .returned(let r):
    gprs[0] = r.status
    gprs[1] = r.detail
    gprs[2] = r.first
    gprs[3] = r.second
    return .resumeEL0
  }
}
