import TarwinABI
import TarwinArchAarch64
import TarwinObject
import TarwinSyscall

@_extern(c, "tarwin_w1_active_host_root") private func activeHost(_ root: UInt64) -> UInt32

@_extern(c, "tarwin_w1_guarded_slice") private func slice(
  _ root: UInt64, _ host: UInt64, _ keys: UnsafePointer<UInt64>,
  _ frame: UnsafeMutableRawPointer, _ cursor: UnsafeMutablePointer<UInt64>,
  _ low: UInt64, _ top: UInt64) -> UInt32

private struct SingleCaller: CurrentProcessContext {
  let process: UnsafeMutablePointer<ProcessExecution>
  let tree: UnsafePointer<JobTree>
  let thread: UInt64
  var services = 0
  mutating func withCaller<R>(_ body: (inout ProcessExecution, borrowing JobTree) -> R) -> R? {
    guard process.pointee.gate(thread, tree: tree.pointee) == .dispatch else { return nil }
    services += 1
    return body(&process.pointee, tree.pointee)
  }
}

/// Single boot CPU, interrupts masked throughout. Store the object graph in
/// the unused last 12 KiB of the pinned host-only context page, not in EL0.
@_cdecl("tarwin_test_process_current") public func processProbe(
  _ context: UnsafeMutableRawPointer, _ root: UInt64, _ host: UInt64,
  _ low: UInt64, _ top: UInt64, _ librarySize: UInt64
) -> UInt32 {
  let lib: UInt64 = 0x1_0001_4000
  guard (4...16384).contains(librarySize) else { return 0 }
  var offset = 4096
  func reserve<T: ~Copyable>(_ type: T.Type) -> UnsafeMutablePointer<T>? {
    let align = MemoryLayout<T>.alignment, size = MemoryLayout<T>.stride
    let start = (offset + align - 1) & ~(align - 1)
    guard start <= 16384, size <= 16384 - start else { return nil }
    offset = start + size
    return (context + start).bindMemory(to: type, capacity: 1)
  }
  guard let j = reserve(JobNode.self), let m = reserve(JobMember.self),
    let slot = reserve(ThreadSlot.self), let cell = reserve(HandleCell.self),
    let parent = reserve(ObjectHeader.self), let task = reserve(ObjectHeader.self),
    let worker = reserve(ObjectHeader.self), let t = reserve(ThreadExecution.self),
    let tree = reserve(JobTree.self), let p = reserve(ProcessExecution.self)
  else { return 0 }
  let ids = KoidSource()
  let limits = JobLimits(processes: 1, threadsPerProcess: 1, handlesPerProcess: 1, footprint: 0,
    cpuShare: 1, maxQos: 0, jetsamBand: 0, ioRank: 0, entitlements: 0, denials: 0, killOnClose: false)
  j.initialize(to: JobNode()); m.initialize(to: JobMember()); slot.initialize(to: ThreadSlot())
  guard let jobHeader = ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0)
  else { return 0 }
  parent.initialize(to: consume jobHeader)
  guard let jobTree = JobTree(jobs: .init(start: j, count: 1), members: .init(start: m, count: 1),
    root: parent.pointee, limits: limits) else { return 0 }
  tree.initialize(to: consume jobTree)
  let key = tree.pointee.root
  guard let processHeader = ObjectHeader(source: ids, ownerJob: key.id, kind: TarwinKind.process,
    maximumRights: 0x500), let threadHeader = ObjectHeader(source: ids, ownerJob: key.id,
      kind: TarwinKind.thread, maximumRights: 0) else { return 0 }
  task.initialize(to: consume processHeader); worker.initialize(to: consume threadHeader)
  guard let process = ProcessExecution(header: .init(task), job: key, tree: tree.pointee,
    slots: .init(start: slot, count: 1), cells: .init(start: cell, count: 1), salt: 37,
    initialMap: root) else { return 0 }
  p.initialize(to: consume process)
  guard let thread = ThreadExecution(header: .init(worker), process: p.pointee.member, job: key)
  else { return 0 }
  t.initialize(to: consume thread)
  let id = worker.pointee.koid
  guard p.pointee.join(t, qos: 0, realtimeEntitled: false, tree: tree.pointee) == .added,
    p.pointee.start(id, tree: tree.pointee) else { return 0 }
  var provider = ProcessCurrentCalls(context: SingleCaller(process: p, tree: .init(tree), thread: id))
  let frame = context + 1024, bank = (context + 512).assumingMemoryBound(to: UInt64.self)
  let cursor = (context + 256).assumingMemoryBound(to: UInt64.self)
  var returned: UInt64 = 0
  for interval in 0..<2 {
    guard activeHost(host) == 1, activeHost(root) == 0,
      p.pointee.gate(id, tree: tree.pointee) == .dispatch,
      slice(root, host, bank, frame, cursor, low, top) == 1,
      frame.load(fromByteOffset: 16 * 8, as: UInt64.self) == TarwinCall.processCurrent
    else { return 0 }
    let userValue = frame.load(as: UInt64.self)
    let decision = dispatchPrivateW1Trap(frame: .init(start: frame, count: ArmTrapLayout.size),
      libraryCode: lib..<lib + librarySize, userRange: 1 << 32..<1 << 47,
      scratch: .init(start: nil, count: 0), provider: &provider)
    guard provider.context.services == 1 else { return 0 }
    if interval == 0 {
      guard case .resumeEL0 = decision, frame.load(as: UInt64.self) == 0 else { return 0 }
      returned = frame.load(fromByteOffset: 16, as: UInt64.self)
    } else {
      guard case .terminateBadOrigin = decision, userValue == returned, returned != 0,
        case .found(let grant) = p.pointee.handleReader.pinWithinEpoch(userValue, kind: TarwinKind.process, need: 0x500)
      else { return 0 }
      var valid = grant.header == p.pointee.header && grant.rights == 0x500
      grant.drop { _ in valid = false }
      return valid ? 1 : 0
    }
  }
  return 0
}
