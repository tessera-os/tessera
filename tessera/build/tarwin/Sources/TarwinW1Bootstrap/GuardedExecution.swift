import TarwinArchAarch64
import TarwinBoot
import TarwinIPCChannels
import TarwinObject
import TarwinProcessKeys
import TarwinRandomCore
import TarwinSyscall

#if hasFeature(Embedded) && arch(arm64) && os(none)
  @_extern(c, "tarwin_w1_guarded_slice")
  private func runSlice(
    _ user: UInt64, _ host: UInt64, _ keys: UnsafePointer<UInt64>,
    _ frame: UnsafeMutableRawPointer, _ cursor: UnsafeMutablePointer<UInt64>,
    _ low: UInt64, _ top: UInt64
  ) -> UInt32
#endif

/// One measured initial thread. Own and pin the backing, archive, roots,
/// frame and key bank until retirement. The frame must be a disjoint
/// kernel-only mapping, never user-addressable or exposed to DMA. All
/// methods run under exclusive task/CPU ownership on a stationary boot CPU.
public struct W1GuardedExecution: ~Copyable {
  fileprivate enum Phase { case ready, captured, stopped }
  fileprivate let user: ArmFinishedUserRoot
  fileprivate let roots: W1ArmDispatchRoots
  fileprivate let task, thread: UnsafePointer<ObjectHeader>
  fileprivate let library, shadow: Range<UInt64>
  fileprivate let frame: UnsafeMutableRawBufferPointer
  fileprivate var cursor: UInt64
  fileprivate var phase = Phase.ready

  /// This is a single synchronous interval, not a scheduler. A successful
  /// call captured an exception, not necessarily a syscall or a valid entry.
  /// Nothing can re-enter this thread until dispatch accepts the capture.
  /// Exclude restoration across the fresh live generation read and use.
  @unsafe public mutating func enter(
    child: borrowing ProcessExecution, selected: borrowing ThreadExecution,
    tree: borrowing JobTree, keys: borrowing ArmProcessKeys,
    generation: W1KernelGeneration,
    host: borrowing ArmFinishedKernelRoot, stacks: ArmStopStacks
  ) -> Bool {
    guard phase == .ready, child.header == task, selected.header == thread,
      stacks.root == host.physical, roots.restored(user: user, host: host),
      shadow.contains(cursor), cursor & 7 == 0, let p = frame.baseAddress
    else { return false }
    let root = user.physical
    let upper = host.physical
    let ran = keys.withThreadKeys(child: child, thread: selected, root: root, tree: tree,
      current: { generation.current(in: host) }) { words in
      guard words.count == 10, let bank = words.baseAddress else { return false }
      #if hasFeature(Embedded) && arch(arm64) && os(none)
        return runSlice(
          root, upper, bank, p, &cursor, stacks.outgoing.lowerBound,
          stacks.outgoing.upperBound) == 1
      #else
        return false
      #endif
    }
    guard ran else { return false }
    guard roots.restored(user: user, host: host) else { phase = .stopped; return false }
    phase = .captured
    return true
  }

  /// Dispatch with host keys but the *captured* child root for any LDTR/STTR
  /// accesses. No provider may schedule, modify translation controls, enable
  /// interrupts, or destroy this root inside the callback. An accepted exit
  /// goes to W1StoppedCaller on the scheduler stack, never another ERET.
  @unsafe public mutating func dispatch<P: CallProvider>(
    host: borrowing ArmFinishedKernelRoot, provider: inout P
  ) -> Arm64TrapOutcome {
    guard phase == .captured else { return .invalidKernelFrame }
    phase = .stopped
    let outcome = roots.dispatch(user: user, host: host, frame: frame, library: library, provider: &provider)
    if w1ArmVectorAction(outcome) == 1 { phase = .ready }
    return outcome
  }
}

extension W1PrivateImages {
  /// Consume the only table writer. Use the original pinned signed members
  /// and archive, stage the child-local Startup frame, join its pinned thread,
  /// then measure precisely this init before making it runnable. Hold tree,
  /// task, channel and TPM ownership throughout. Tear down on any failure.
  @unsafe public consuming func startMeasuredFirstThread<P: TpmPort>(
    _ bootstrap: ChildBootstrap,
    child: inout ProcessExecution, thread: UnsafeMutablePointer<ThreadExecution>,
    tree: borrowing JobTree,
    channel: borrowing ChannelPair, framePage: consuming W1TrapFrameReservation,
    host: borrowing ArmFinishedKernelRoot,
    previousPCR10: InlineArray<32, UInt8>, port: inout P,
    state: inout MeasurementLog, log: UnsafeMutableRawBufferPointer
  ) -> W1GuardedExecution? {
    guard thread.pointee.process == child.member, thread.pointee.phase == .created,
      child.threadCount == 0,
      let storage = initialThread,
      host.physical == clockHost,
      let frame = framePage.open(in: host,
        pool: tables.physicalRoot..<tables.physicalRoot + UInt64(usedBytes), clock: clockFrame),
      let gcs = stageGuardedFirstFrame(
        bootstrap, child: child, tree: tree, channel: channel,
        into: frame)
    else { return nil }
    let rx = libraryCode
    guard let root = tables.finish(), root.physical == gcs.root,
      let roots = W1ArmDispatchRoots(user: root, host: host),
      child.join(thread, qos: 0, realtimeEntitled: false, tree: tree) == .added,
      measureAuthorizedQEMUInit(
        authorized, in: archive, previousPCR10: previousPCR10, port: &port,
        state: &state, log: log),
      child.start(thread.pointee.header.pointee.koid, tree: tree)
    else { return nil }
    return W1GuardedExecution(
      user: root, roots: roots, task: child.header, thread: thread.pointee.header,
      library: rx, shadow: storage.shadow, frame: frame, cursor: gcs.pointer)
  }
}
