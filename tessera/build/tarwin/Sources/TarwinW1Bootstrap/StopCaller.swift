import TarwinArchAarch64
import TarwinObject
import TarwinSyscall

/// Capture the trusted CPU's current thread under scheduler/task locks
/// after exit was accepted. Store in stable per-CPU memory, never on the
/// outgoing stack. The vector keeps interrupts masked through the switch.
public struct W1StoppedCaller: ~Copyable {
  private let process: ProcessKey
  private let id: UInt64
  private let stacks: ArmStopStacks
  private let capture: W1ArmDispatchRoots?

  public init?(
    outcome: Arm64TrapOutcome, child: borrowing ProcessExecution,
    thread: borrowing ThreadExecution, stacks: ArmStopStacks
  ) {
    self.init(outcome: outcome, child: child, thread: thread, stacks: stacks, capture: nil)
  }

  init?(outcome: Arm64TrapOutcome, child: borrowing ProcessExecution,
    thread: borrowing ThreadExecution, stacks: ArmStopStacks, capture: W1ArmDispatchRoots?) {
    guard capture?.onOriginalRoots(host: stacks.root) != false,
      outcome == .stopCaller, child.phase == .stopping, child.member == thread.process,
      thread.phase == .runnable
    else { return nil }
    self.process = child.member
    self.id = thread.header.pointee.koid
    self.stacks = stacks
    self.capture = capture
  }

  public func destination(frame: UInt64, hostRoot: UInt64) -> UInt64? {
    capture == nil ? stacks.destination(frame: frame, hostRoot: hostRoot) : nil
  }

  /// The guarded interval already saved the registers to a pinned page and
  /// unwound the capture stack. Use the CPU's live SP, not a pretend frame.
  public func destinationAfterCapture(sp: UInt64, hostRoot: UInt64) -> UInt64? {
    guard capture?.onOriginalRoots(host: hostRoot) == true, hostRoot == stacks.root, sp & 15 == 0,
      sp > stacks.outgoing.lowerBound, sp <= stacks.outgoing.upperBound else { return nil }
    return stacks.scheduler.upperBound
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
    guard capture?.onOriginalRoots(host: hostRoot) != false, hostRoot == stacks.root, sp & 15 == 0,
      sp > stacks.scheduler.lowerBound, sp <= stacks.scheduler.upperBound,
      child.member == process, child.phase == .stopping, let cause = child.exit
    else { return false }
    return child.stopped(id, code: cause.code, tree: tree, notify: notify, retire: retire)
  }
}
