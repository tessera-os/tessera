import TarwinArchAarch64
import TarwinObject
import TarwinSyscall

/// Private assembly interface, after the scheduler's final return gate.
/// Never convert a syscall status, result GPR,
/// or a Swift enum's in-memory representation into a vector action.
public func w1ArmVectorAction(_ outcome: Arm64TrapOutcome) -> UInt32 {
  switch outcome {
  case .resumeEL0: return 1
  case .stopCaller: return 2
  case .terminateBadOrigin, .otherSynchronousException, .invalidKernelFrame: return 0
  }
}

/// Capture the trusted CPU's current thread under scheduler/task locks
/// after exit was accepted. Store in stable per-CPU memory, never on the
/// outgoing stack. The vector keeps interrupts masked through the switch.
public struct W1StoppedCaller: ~Copyable {
  private let process: ProcessKey
  private let id: UInt64
  private let stacks: ArmStopStacks

  public init?(
    outcome: Arm64TrapOutcome, child: borrowing ProcessExecution,
    thread: borrowing ThreadExecution, stacks: ArmStopStacks
  ) {
    guard outcome == .stopCaller, child.phase == .stopping, child.member == thread.process,
      thread.phase == .runnable
    else { return nil }
    self.process = child.member
    self.id = thread.header.pointee.koid
    self.stacks = stacks
  }

  public func destination(frame: UInt64, hostRoot: UInt64) -> UInt64? {
    stacks.destination(frame: frame, hostRoot: hostRoot)
  }

  /// Only from the assembly continuation on the new stack: sp/hostRoot
  /// are sampled by the CPU, never from a saved user frame. Under the tree,
  /// process and thread observer locks, acknowledge only the captured thread.
  /// Address-space teardown still waits for TTBR0 retirement and read epochs.
  public consuming func acknowledge(
    sp: UInt64, hostRoot: UInt64, child: inout ProcessExecution,
    tree: borrowing JobTree, notify: (UnsafePointer<ObjectHeader>) -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard hostRoot == stacks.root, sp & 15 == 0,
      sp > stacks.scheduler.lowerBound, sp <= stacks.scheduler.upperBound,
      child.member == process, child.phase == .stopping, let cause = child.exit
    else { return false }
    return child.stopped(id, code: cause.code, tree: tree, notify: notify, retire: retire)
  }
}
