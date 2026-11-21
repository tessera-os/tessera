import TarwinArchAarch64
import TarwinSyscall

#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
  @_extern(c, "tarwin_w1_active_host_root") private func activeHost(_ root: UInt64) -> UInt32
  @_extern(c, "tarwin_w1_prior_root") private func lowerRoot() -> UInt64
  @_extern(c, "tarwin_w1_retire_slice_root")
  private func retireRoot(_ prior: UInt64, _ user: UInt64, _ host: UInt64)
#endif

/// The boot CPU's original lower and upper roots stay pinned and immutable
/// for the entire first thread. No migration, scheduling or interrupts.
struct W1ArmDispatchRoots {
  private let prior, child, kernel: UInt64

  init?(user: borrowing ArmFinishedUserRoot, host: borrowing ArmFinishedKernelRoot) {
    guard user.layout == .guarded, host.layout == .guarded, user.physical != host.physical
    else { return nil }
    #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
      guard activeHost(host.physical) == 1 else { return nil }
      let before = lowerRoot()
      guard before != user.physical, before != host.physical, before != 0,
        before < 1 << 48, before & 16383 == 0 else { return nil }
      prior = before; child = user.physical; kernel = host.physical
    #else
      return nil
    #endif
  }

  func restored(user: borrowing ArmFinishedUserRoot, host: borrowing ArmFinishedKernelRoot) -> Bool {
    #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
      return user.physical == child && host.physical == kernel &&
        user.layout == .guarded && host.layout == .guarded && activeHost(kernel) == 1 && lowerRoot() == prior
    #else
      return false
    #endif
  }

  @unsafe func dispatch<P: CallProvider>(
    user: borrowing ArmFinishedUserRoot, host: borrowing ArmFinishedKernelRoot,
    frame: UnsafeMutableRawBufferPointer, library: Range<UInt64>, provider: inout P
  ) -> Arm64TrapOutcome {
    #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
      guard restored(user: user, host: host), switchArmUserRoot(user, host: host)
      else { return .invalidKernelFrame }
      var scratch = InlineArray<32, UInt64>(repeating: 0)
      let outcome = withUnsafeMutableBytes(of: &scratch) {
        dispatchPrivateW1Trap(frame: frame, libraryCode: library, userRange: 1 << 32..<1 << 47,
          scratch: $0.bindMemory(to: UInt64.self), provider: &provider)
      }
      retireRoot(prior, child, kernel)
      return restored(user: user, host: host) ? outcome : .invalidKernelFrame
    #else
      return .invalidKernelFrame
    #endif
  }
}

/// Only a resume decision, never a syscall status, permits another interval.
public func w1ArmVectorAction(_ outcome: Arm64TrapOutcome) -> UInt32 {
  switch outcome {
  case .resumeEL0: return 1
  case .stopCaller: return 2
  case .terminateBadOrigin, .otherSynchronousException, .invalidKernelFrame: return 0
  }
}

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
