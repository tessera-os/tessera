import TarwinArchAarch64
import TarwinObject
import TarwinSyscall

@_extern(c, "tarwin_w1_prior_root") private func lowerRoot() -> UInt64

private struct ExitCaller: ExitingProcessContext {
  let process: UnsafeMutablePointer<ProcessExecution>
  let tree: UnsafePointer<JobTree>
  let id: UInt64
  var stops = 0

  mutating func withExitingCaller(
    _ body: (inout ProcessExecution, borrowing JobTree, (UInt64) -> Void) -> Bool
  ) -> Bool? {
    guard process.pointee.initialMap == lowerRoot(),
      process.pointee.gate(id, tree: tree.pointee) == .dispatch else { return nil }
    return body(&process.pointee, tree.pointee) { stops += $0 == id ? 1 : 2 }
  }
}

private struct PendingExit: ~Copyable {
  let stopped: W1StoppedCaller
  let process: UnsafeMutablePointer<ProcessExecution>
  let thread: UnsafePointer<ThreadExecution>
  let tree: UnsafePointer<JobTree>
  let prior: UInt64
}

private func pending(_ context: UnsafeMutableRawPointer) -> UnsafeMutablePointer<PendingExit> {
  (context + 2048).assumingMemoryBound(to: PendingExit.self)
}

// Only the exit fixture writes this record, on the sole boot CPU. The
// pointers refer to pinned host context storage, never the outgoing stack.
func queueExit(_ context: UnsafeMutableRawPointer, _ dispatch: W1ArmDispatchRoots,
  _ saved: UnsafeMutableRawBufferPointer, _ library: Range<UInt64>, _ prior: UInt64,
  _ process: UnsafeMutablePointer<ProcessExecution>, _ thread: UnsafePointer<ThreadExecution>,
  _ tree: UnsafePointer<JobTree>) -> UInt32 {
  let roots = (context + 128).assumingMemoryBound(to: ProbeRoots.self)
  let stacks = (context + 64).assumingMemoryBound(to: ArmStopStacks.self)
  let id = thread.pointee.header.pointee.koid
  var calls = ProcessExitCalls(context: ExitCaller(process: process, tree: tree, id: id))
  let result = dispatch.dispatch(user: roots.pointee.b, host: roots.pointee.host,
    frame: saved, library: library, provider: &calls)
  guard calls.context.stops == 1, lowerRoot() == prior, process.pointee.threadCount == 1,
    thread.pointee.phase == .runnable, process.pointee.gate(id, tree: tree.pointee) == .stop,
    process.pointee.exit == TaskExit(.exited, code: -71),
    let stopped = W1StoppedCaller(outcome: result, child: process.pointee,
      thread: thread.pointee, stacks: stacks.pointee, capture: dispatch),
    stopped.destinationAfterCapture(sp: stacks.pointee.outgoing.lowerBound, hostRoot: stacks.pointee.root) == nil,
    stopped.destinationAfterCapture(sp: stacks.pointee.scheduler.upperBound, hostRoot: stacks.pointee.root) == nil,
    stopped.destinationAfterCapture(sp: stacks.pointee.outgoing.upperBound - 1, hostRoot: stacks.pointee.root) == nil,
    stopped.destinationAfterCapture(sp: stacks.pointee.outgoing.upperBound, hostRoot: stacks.pointee.root) == stacks.pointee.scheduler.upperBound,
    MemoryLayout<PendingExit>.stride <= 1024 else { return 0 }
  pending(context).initialize(to: PendingExit(stopped: consume stopped, process: process,
    thread: thread, tree: tree, prior: prior))
  context.storeBytes(of: UInt64(1), toByteOffset: 2016, as: UInt64.self)
  return w1ArmVectorAction(result)
}

func exitStack(_ context: UnsafeMutableRawPointer, _ sp: UInt64, _ root: UInt64) -> UInt64 {
  guard context.load(fromByteOffset: 2016, as: UInt64.self) == 1,
    pending(context).pointee.prior == lowerRoot() else { return 0 }
  return pending(context).pointee.stopped.destinationAfterCapture(sp: sp, hostRoot: root) ?? 0
}

@_cdecl("tarwin_test_ack_exit")
public func acknowledgeExit(_ context: UnsafeMutableRawPointer, _ sp: UInt64, _ root: UInt64) -> UInt32 {
  guard context.load(fromByteOffset: 2016, as: UInt64.self) == 1 else { return 0 }
  context.storeBytes(of: UInt64(0), toByteOffset: 2016, as: UInt64.self)
  let record = pending(context).move()
  let t = record.thread, p = record.process
  var notified = 0
  guard lowerRoot() == record.prior, p.pointee.threadCount == 1,
    record.stopped.acknowledge(sp: sp, hostRoot: root, child: &p.pointee, tree: record.tree.pointee,
      notify: { notified += $0 == t.pointee.header ? 1 : 2 }, retire: { _ in notified += 2 }),
    notified == 1, p.pointee.threadCount == 0, t.pointee.phase == .terminated,
    t.pointee.exitCode == -71 else { return 0 }
  return 1
}
