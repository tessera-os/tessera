import LibTesseraTarwin
import Tarboot
import TarwinABI
import TarwinChannelCalls
import TarwinIPC
import TarwinIPCChannels
import TarwinIPCObservers
import TarwinObject
import TarwinObjectCalls
import TarwinSched
import TarwinSync
import TarwinSyncObjects
import TarwinSyscall

#if arch(arm64)
  import TarwinArchAarch64
  import TarwinArmBootstrap
  import TarwinKernelRandom
  import TarwinProcessKeys
  import TarwinRandomCore
#endif

private struct Arena {
  var remaining: UnsafeMutableRawBufferPointer
  // The caller exclusively owns uninitialized, page-aligned firmware pages.
  // Carve disjoint regions and bind each to exactly one type until release.
  mutating func take<T: ~Copyable>(_ type: T.Type, count: Int) -> UnsafeMutableBufferPointer<T> {
    let p = remaining.baseAddress!
    let skip = (0 &- UInt(bitPattern: p)) % UInt(MemoryLayout<T>.alignment)
    let extent = Int(skip) + MemoryLayout<T>.stride * count
    precondition(extent <= remaining.count)
    let start = p.advanced(by: Int(skip)).bindMemory(to: T.self, capacity: count)
    remaining = UnsafeMutableRawBufferPointer(rebasing: remaining[extent...])
    return .init(start: start, count: count)
  }
}

private struct Lifecycle: HandleRetirement {
  var retired: UInt64 = 0, removed: UInt64 = 0
  mutating func retire(_ p: UnsafePointer<ObjectHeader>) { retired = p.pointee.koid }
  mutating func invalidate(_ name: UInt64) { removed = name }
}
private struct LocalContext: HandleCallContext {
  let table: UnsafeMutablePointer<HandleTable>
  let epoch: UnsafePointer<EpochDomain>
  var life = Lifecycle()
  var userRange: Range<UInt64> { 0..<0 }
  // No user mapping in this firmware test. Only register-only calls can work.
  func readWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool { false }
  func writeWords(to: UInt64, from: UnsafeBufferPointer<UInt64>) -> Bool { false }
  mutating func withWriter<R>(_ body: (inout HandleTable, inout Lifecycle) -> R) -> R {
    body(&table.pointee, &life)
  }
  mutating func withRead<R>(_ body: (HandleReadView, inout Lifecycle) -> R) -> R {
    epoch.pointee.withRead { body(table.pointee.reader, &life) }
  }
}
private struct RegisterGate<P: CallProvider>: NativeGate {
  var calls: P
  var isa: CallISA {
    #if arch(arm64)
      .aarch64
    #elseif arch(x86_64)
      .x64
    #elseif arch(riscv64)
      .rv64
    #else
      #error("Unsupported diagnostic ISA")
    #endif
  }
  // Feed a saved PC to the dispatcher, not a privilege transition.
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    var scratch = InlineArray<5, UInt64>(repeating: 0)
    let arch = isa
    let d = withUnsafeMutableBytes(of: &scratch) {
      dispatchCall(
        isa: arch, savedPC: arch == .rv64 ? 4096 : 4096 + arch.instructionWidth,
        libraryCode: 4096..<4112, userRange: 0..<0, number: number, registers: registers,
        scratch: $0.bindMemory(to: UInt64.self), provider: &calls)
    }
    if case .returned(let r) = d { return r }
    return CallResult(status: .max)
  }
}

private struct Caller: CurrentProcessContext, ExitingProcessContext {
  let process: UnsafeMutablePointer<ProcessExecution>
  let tree: UnsafePointer<JobTree>
  var stopping: UInt64 = 0
  func withCaller<R>(_ body: (inout ProcessExecution, borrowing JobTree) -> R) -> R? {
    body(&process.pointee, tree.pointee)
  }
  mutating func withExitingCaller(
    _ body: (inout ProcessExecution, borrowing JobTree, (UInt64) -> Void) -> Bool
  ) -> Bool? {
    body(&process.pointee, tree.pointee, { self.stopping = $0 })
  }
}

private func exitCaller(_ process: inout ProcessExecution, tree: borrowing JobTree, thread: UInt64)
  -> Bool
{
  withUnsafeMutablePointer(to: &process) { p in
    withUnsafePointer(to: tree) { j in
      var calls = ProcessExitCalls(context: Caller(process: p, tree: j))
      var scratch: UInt64 = 0
      let isa = RegisterGate(calls: calls).isa
      let effect = withUnsafeMutablePointer(to: &scratch) { word in
        dispatchCall(
          isa: isa, savedPC: isa == .rv64 ? 4096 : 4096 + isa.instructionWidth,
          libraryCode: 4096..<4112, userRange: 0..<0, number: TarwinSyscall.TarwinCall.processExit,
          registers: CallRegisters(UInt64(bitPattern: -37)), scratch: .init(start: word, count: 1),
          provider: &calls)
      }
      guard case .stopCaller = effect else { return false }
      return calls.context.stopping == thread && p.pointee.exit == TaskExit(.exited, code: -37)
    }
  }
}

private func selfHandle(_ process: inout ProcessExecution, tree: borrowing JobTree) -> UInt64 {
  withUnsafeMutablePointer(to: &process) { p in
    withUnsafePointer(to: tree) { j in
      var gate = RegisterGate(calls: ProcessCurrentCalls(context: Caller(process: p, tree: j)))
      let a = NativeProcess.current(gate: &gate)
      return a == NativeProcess.current(gate: &gate) ? a : 0
    }
  }
}

private struct PrivatePair: ChannelNamespace {
  let pair: UnsafeMutablePointer<ChannelPair>, table: UnsafeMutablePointer<HandleTable>
  mutating func withPair(
    named: UInt64, _ body: (inout ChannelPair, inout HandleTable) -> CallResult
  ) -> CallResult {
    body(&pair.pointee, &table.pointee)
  }
}

// Only the two preallocated diagnostic buffers, never user memory.
private struct PrivateOutput: ChannelUserOutput {
  let b: UnsafeMutableRawBufferPointer, h: UnsafeMutableBufferPointer<UInt64>
  var userRange: Range<UInt64> { 1..<UInt64.max }
  mutating func withWritable(
    bytes: Range<UInt64>, names: Range<UInt64>,
    _ body: (UnsafeMutableRawBufferPointer, UnsafeMutableBufferPointer<UInt64>) -> CallResult
  ) -> CallResult? {
    guard bytes.lowerBound == UInt64(UInt(bitPattern: b.baseAddress)),
      bytes.count == b.count, names.lowerBound == UInt64(UInt(bitPattern: h.baseAddress)),
      names.count == h.count * 8
    else { return nil }
    return body(b, h)
  }
}

extension PrivateOutput: ChannelUserInput {
  func withCaptured(
    names: Range<UInt64>, bytes: Range<UInt64>?,
    _ body: (UnsafeBufferPointer<UInt64>, UnsafeRawBufferPointer?) -> CallResult
  ) -> CallResult? {
    guard names.lowerBound == UInt64(UInt(bitPattern: h.baseAddress)), names.count == h.count * 8
    else { return nil }
    guard let bytes, bytes.lowerBound == UInt64(UInt(bitPattern: b.baseAddress)),
      bytes.count == b.count
    else { return body(.init(h), nil) }
    return body(.init(h), .init(b))
  }
}

private func queuedWrite(
  _ pair: inout ChannelPair, header: UnsafePointer<ObjectHeader>, table: inout HandleTable,
  name: inout UInt64, scratch: UnsafeMutableRawBufferPointer
) -> Bool {
  guard case .installed(let writer) = table.install(header, rights: 8) else { return false }
  scratch[0] = 71
  let sent = withUnsafeMutablePointer(to: &name) { hp in
    withUnsafeMutablePointer(to: &table) { tp in
      withUnsafeMutablePointer(to: &pair) { qp in
        let memory = PrivateOutput(b: .init(rebasing: scratch[..<1]), h: .init(start: hp, count: 1))
        var gate = RegisterGate(
          calls: ChannelWriteCalls(
            space: PrivatePair(pair: qp, table: tp),
            memory: memory, lifecycle: Lifecycle()))
        let r = NativeChannels.write(
          writer, bytes: .init(memory.b), names: .init(memory.h), gate: &gate)
        return r.status == 0 && gate.calls.lifecycle.removed == hp.pointee
      }
    }
  }
  let old = name
  var size = ChannelSize()
  scratch[0] = 0
  return sent && table.close(writer) { _ in }
    && withUnsafeMutablePointer(to: &name) {
      pair.receive(
        at: .b, into: scratch, names: .init(start: $0, count: 1), table: &table, size: &size)
    } == .ok && size.handles == 1 && size.bytes == 1 && scratch[0] == 71 && name != old
}

private func bootstrapChannel(
  _ arena: inout Arena, process: inout ProcessExecution, tree: borrowing JobTree,
  ids: borrowing KoidSource, job: UnsafePointer<ObjectHeader>, roots: UnsafeMutableRawBufferPointer
) -> Bool {
  let heads = arena.take(ObjectHeader.self, count: 2)
  for i in heads.indices {
    (heads.baseAddress! + i).initialize(
      to: ObjectHeader(
        source: ids, ownerJob: process.job.id, kind: TarwinKind.channel,
        maximumRights: i == 0 ? 8 : 4)!)
  }
  let sizes = arena.take(ChannelSize.self, count: 2)
  let grants = arena.take(ObjectGrant.self, count: 128)
  let payload = arena.take(UInt8.self, count: 112)
  let scratch = arena.take(UInt8.self, count: 56)
  let cells = arena.take(HandleCell.self, count: 2)
  sizes.initialize(repeating: ChannelSize())
  var staging = HandleTable(storage: cells, salt: 8)!
  defer {
    cells.deinitialize()
    sizes.deinitialize()
    heads.deinitialize()
  }
  func queue(_ i: Int) -> ChannelQueue {
    ChannelQueue(
      lengths: .init(rebasing: sizes[i...i]),
      bytes: .init(UnsafeMutableBufferPointer(rebasing: payload[(i * 56)..<(i * 56 + 56)])),
      grants: .init(start: grants.baseAddress! + i * 64, count: 64))!
  }
  guard
    var pair = ChannelPair(
      a: .init(heads.baseAddress!), b: .init(heads.baseAddress! + 1),
      toA: queue(0), toB: queue(1)),
    case .installed(var jobName) = staging.install(job, rights: 258)
  else { return false }
  guard
    process.withHandles(
      tree: tree,
      { table in
        serviceRoundTrip(pair, client: &staging, worker: &table, name: &jobName, arena: &arena)
      }) == true
  else { return false }
  var tag: UInt32 = 13
  guard
    queuedWrite(
      &pair, header: .init(heads.baseAddress!), table: &staging, name: &jobName,
      scratch: .init(scratch))
  else { return false }
  var invalidated: UInt64 = 0
  let token = withUnsafePointer(to: &tag) { tp in
    withUnsafePointer(to: &jobName) { np in
      pair.preloadStartup(
        child: &process, tree: tree, app: 123, flags: 2,
        tags: .init(start: tp, count: 1), names: .init(start: np, count: 1),
        staging: &staging, scratch: .init(scratch), invalidate: { invalidated = $0 },
        retire: { _ in })
    }
  }
  guard let token, invalidated == jobName, staging.count == 0,
    let name = pair.entryName(token, child: process, tree: tree, initialMap: process.initialMap),
    tree.setFrozen(true, job: tree.root),
    pair.entryName(token, child: process, tree: tree, initialMap: process.initialMap) == nil,
    tree.setFrozen(false, job: tree.root),
    pair.entryName(token, child: process, tree: tree, initialMap: process.initialMap) == name
  else { return false }
  #if arch(arm64)
    guard checkFrames(roots, process: process, tree: tree, pair: pair, token: token, name: name)
    else { return false }
  #endif
  var received: UInt64 = 0
  let ok = process.withHandles(tree: tree) { table in
    withUnsafeMutablePointer(to: &received) { hp in
      withUnsafeMutablePointer(to: &table) { tp in
        withUnsafeMutablePointer(to: &pair) { qp in
          let memory = PrivateOutput(b: .init(scratch), h: .init(start: hp, count: 1))
          var gate = RegisterGate(
            calls: ChannelReceiveCalls(space: PrivatePair(pair: qp, table: tp), memory: memory))
          let peek = NativeChannels.peek(name, gate: &gate)
          let read = NativeChannels.read(name, into: memory.b, names: memory.h, gate: &gate)
          return peek.status == 0 && peek.first == 56 && peek.second == 1
            && read.status == 0 && read.first == peek.first && read.second == peek.second
            && NativeChannels.peek(name, gate: &gate).code == 27
        }
      }
    }
  }
  guard ok == true, received != 0, received != jobName,
    pair.entryName(token, child: process, tree: tree, initialMap: process.initialMap) == nil,
    case .found(let pin) = process.handleReader.pinWithinEpoch(
      received, kind: TarwinKind.job, need: 256)
  else { return false }
  let correctJob = pin.header == job && pin.rights == 258
  pin.drop { _ in }
  var entry = StartupEntry()
  let identity = withUnsafeMutablePointer(to: &entry) { ep in
    withUnsafePointer(to: &received) { hp in
      StartupIdentity.decode(
        .init(scratch), received: .init(start: hp, count: 1), into: .init(start: ep, count: 1))
    }
  }
  guard correctJob, identity?.process == process.member.id, identity?.job == process.job.id,
    entry.tag == 13, entry.name == received,
    process.withHandles(
      tree: tree, { $0.close(received, retire: { _ in }) && $0.close(name, retire: { _ in }) })
      == true,
    pair.entryName(token, child: process, tree: tree, initialMap: process.initialMap) == nil
  else { return false }
  pair.close(.b, retire: { _ in })
  return heads.baseAddress!.pointee.release() == .destroy
    && (heads.baseAddress! + 1).pointee.release() == .destroy
}

// Single boot CPU; do not put a run queue on the firmware entry stack.
nonisolated(unsafe) private var cpu = BootstrapCPU(now: 0, identity: 1)

/// Run before the startup preload, with the child/staging tables still
/// private. Return the moved grant under its new name for the startup send.
private func serviceRoundTrip(
  _ pair: borrowing ChannelPair, client: inout HandleTable,
  worker: inout HandleTable, name: inout UInt64, arena: inout Arena
) -> Bool {
  let memory = arena.take(UInt8.self, count: 192)
  let cells = arena.take(UInt64.self, count: 3)
  let sizes = arena.take(ChannelSize.self, count: 2)
  cells.initialize(repeating: 0)
  sizes.initialize(repeating: ChannelSize())
  defer {
    cells.deinitialize()
    sizes.deinitialize()
  }
  func segment(_ i: Int) -> UnsafeMutableRawBufferPointer {
    .init(start: memory.baseAddress! + i * 64, count: 64)
  }
  func names(_ i: Int) -> UnsafeMutableBufferPointer<UInt64> {
    .init(start: cells.baseAddress! + i, count: 1)
  }
  func area(_ i: Int, _ table: borrowing HandleTable) -> ServiceArea {
    ServiceArea(bytes: segment(i), names: names(i), size: sizes.baseAddress! + i, table: table)
  }
  func message(_ i: Int) -> ServiceMessage {
    .init(bytes: .init(segment(i)), names: .init(names(i)))
  }
  cells[2] = name
  for i in 0..<64 { segment(2)[i] = UInt8(i) }
  guard cpu.create(id: 1, qos: SchedClass.background),
    cpu.create(id: 2, qos: SchedClass.interactive),
    cpu.wake(1, now: 0), cpu.select(now: 0) == 1,
    let wait = pair.waitForRequest(at: .b, into: area(1, worker), cpu: &cpu, now: 1),
    cpu.wake(2, now: 1), cpu.select(now: 1) == 2,
    var call = pair.directCall(
      from: .a, waiting: wait, transaction: 3, deadline: 10,
      now: 2, cpu: &cpu, message: message(2), replyTo: area(0, client),
      sender: &client, receiver: &worker, invalidate: { _ in }),
    cpu.running == 1, cpu.charging == 2, sizes[1].handles == 1, sizes[1].bytes == 64,
    client.count == 0, worker.count == 1, pair.peek(at: .b) == nil,
    call.reply(
      transaction: 3, channel: pair, now: 3, cpu: &cpu, message: message(1), sender: &worker,
      receiver: &client, invalidate: { _ in }),
    cpu.running == 2, cpu.charging == 2, sizes[0].handles == 1, sizes[0].bytes == 64,
    worker.count == 0, client.count == 1, cells[0] != name, pair.peek(at: .a) == nil
  else { return false }
  for i in 0..<64 where segment(0)[i] != UInt8(i) { return false }
  name = cells[0]
  return true
}

#if arch(arm64)
  /// Two never-installed roots with equally valid descriptors. Only one
  /// belongs to the child. The leaf frames contain no executable image.
  private func checkFrames(
    _ roots: UnsafeMutableRawBufferPointer,
    process: borrowing ProcessExecution, tree: borrowing JobTree, pair: borrowing ChannelPair,
    token: ChildBootstrap, name: UInt64
  ) -> Bool {
    let page = 16384
    let pc: UInt64 = 1 << 32
    let ordinary: UInt64 = 1 << 43
    let rx = pc..<pc + 32
    let stack = ordinary + 65536..<ordinary + 81920
    let tcb = ordinary + 81920
    for i in 0..<2 {
      let memory = UnsafeMutableRawBufferPointer(
        rebasing: roots[i * 11 * page..<(i * 11 + 8) * page])
      let root = UInt64(UInt(bitPattern: memory.baseAddress))
      let leaf = root + UInt64(8 * page)
      guard var tables = ArmUserTranslation(backing: memory, physical: root),
        tables.insert(virtual: pc, physical: leaf, write: false, execute: true),
        tables.insert(
          virtual: stack.lowerBound, physical: leaf + 16384, write: true, execute: false),
        tables.insert(virtual: tcb, physical: leaf + 32768, write: true, execute: false),
        ArmInitialState(
          tables: tables, entry: pc + 16, imageRX: rx, bootstrapChannel: name,
          stack: stack, tcb: tcb) != nil
      else { return false }
      let frame = initialArmChildFrame(
        token, child: process, tree: tree, channel: pair,
        tables: tables, entry: pc + 16, imageRX: rx, stack: stack, tcb: tcb)
      if i == 0 {
        guard let frame, frame.gpr[0] == name, frame.elr == pc + 16,
          frame.sp == stack.upperBound, frame.tpidr == tcb
        else { return false }
        for reg in 1..<31 where frame.gpr[reg] != 0 { return false }
      } else if frame != nil {
        return false
      }
    }
    return true
  }
#endif

#if arch(arm64)
  // Fixed diagnostic material, never a launch input or hardware entropy.
  private func fixtureKeys(
    _ child: inout ProcessExecution, tree: borrowing JobTree, root: UInt64,
    bank: UnsafeMutableBufferPointer<UInt64>
  ) -> ArmProcessKeys? {
    var seed = InlineArray<96, UInt8>(repeating: 0x5a)
    return withUnsafeMutableBytes(of: &seed) { input in
      let epoch = RandomEpoch.virtualMachine(low: 1, high: 2)
      guard
        var random = KernelRandom(
          policy: .debugQEMU, bootSeed: .init(rebasing: UnsafeRawBufferPointer(input)[..<64]),
          hardware: .init(rebasing: UnsafeRawBufferPointer(input)[64...]), source: .emulatedTPM,
          generation: epoch)
      else { return nil }
      return ArmProcessKeys(
        child: &child, root: root, tree: tree, storage: bank, random: &random, generation: epoch)
    }
  }
#endif

private func jobQuota(_ arena: inout Arena, _ limit: UInt64) -> Bool {
  #if arch(arm64)
    let padding = (0 &- UInt(bitPattern: arena.remaining.baseAddress)) & 16383
    let extent = Int(padding) + 22 * 16384
    guard extent <= arena.remaining.count else { return false }
    let roots = UnsafeMutableRawBufferPointer(rebasing: arena.remaining[Int(padding)..<extent])
    arena.remaining = .init(rebasing: arena.remaining[extent...])
    let initialMap: UInt64? = UInt64(UInt(bitPattern: roots.baseAddress))
  #else
    let roots = UnsafeMutableRawBufferPointer(start: nil, count: 0)
    let initialMap: UInt64? = nil
  #endif
  let jobs = arena.take(JobNode.self, count: 2)
  let members = arena.take(JobMember.self, count: 1)
  jobs.initialize(repeating: JobNode())
  members.initialize(repeating: JobMember())
  defer {
    jobs.deinitialize()
    members.deinitialize()
  }
  let ids = KoidSource()
  let policy = JobLimits(
    processes: 1, threadsPerProcess: 4, handlesPerProcess: 8, footprint: limit,
    cpuShare: 1, maxQos: 2, jetsamBand: 2, ioRank: 0, entitlements: 0, denials: 0,
    killOnClose: false)
  guard let root = ObjectHeader(source: ids, ownerJob: 0, kind: TarwinKind.job, maximumRights: 0),
    let tree = JobTree(jobs: jobs, members: members, root: root, limits: policy),
    let child = ObjectHeader(
      source: ids, ownerJob: root.koid, kind: TarwinKind.job, maximumRights: 258),
    let branch = tree.create(child, under: tree.root, policy: policy),
    let process = ObjectHeader(
      source: ids, ownerJob: child.koid, kind: TarwinKind.process, maximumRights: 0x500),
    let thread = ObjectHeader(
      source: ids, ownerJob: child.koid, kind: TarwinKind.thread, maximumRights: 0)
  else { return false }
  let slots = arena.take(ThreadSlot.self, count: 1)
  let cells = arena.take(HandleCell.self, count: 2)
  slots.initialize(repeating: ThreadSlot())
  defer { slots.deinitialize() }
  return withUnsafePointer(to: process) { ph in
    guard
      var p = ProcessExecution(
        header: ph, job: branch, tree: tree, slots: slots, cells: cells, salt: 3,
        initialMap: initialMap)
    else { return false }
    defer { cells.deinitialize() }
    #if arch(arm64)
      let bank = arena.take(UInt64.self, count: 10)
      bank.initialize(repeating: 0)
      defer { bank.deinitialize() }
      let root = initialMap!
      guard let keys = fixtureKeys(&p, tree: tree, root: root, bank: bank),
        keys.withImportIA(child: p, root: root, tree: tree, { $0.count == 2 ? 1 : nil }) == 1,
        keys.withImportIA(child: p, root: root + 16384, tree: tree, { _ in 1 }) == nil
      else { return false }
    #endif
    guard
      withUnsafePointer(
        to: child,
        { bootstrapChannel(&arena, process: &p, tree: tree, ids: ids, job: $0, roots: roots) })
    else { return false }
    let result = withUnsafePointer(to: thread) { th in
      guard var t = ThreadExecution(header: th, process: p.member, job: branch) else {
        return false
      }
      return withUnsafeMutablePointer(to: &t) { tp in
        let id = th.pointee.koid
        guard tree.resizeFootprint(p.member, to: limit),
          !tree.resizeFootprint(p.member, to: limit + 1),
          tree.usage(tree.root)?.footprint == limit,
          p.join(tp, qos: 2, realtimeEntitled: false, tree: tree) == .added,
          p.gate(id, tree: tree) == .hold,
          p.start(id, tree: tree),
          p.gate(id, tree: tree) == .dispatch
        else { return false }
        #if arch(arm64)
          guard
            keys.withThreadKeys(
              child: p, thread: tp.pointee, root: root, tree: tree,
              {
                $0.count == 10 && $0.baseAddress == UnsafePointer(bank.baseAddress)
              }), keys.withImportIA(child: p, root: root, tree: tree, { _ in 1 }) == nil
          else { return false }
        #endif
        guard case let own = selfHandle(&p, tree: tree), own != 0,
          case .installed(let name)? = p.withHandles(tree: tree, { $0.install(th, rights: 0) }),
          tree.setFrozen(true, job: tree.root), p.gate(id, tree: tree) == .hold,
          tree.setFrozen(false, job: tree.root), exitCaller(&p, tree: tree, thread: id),
          p.gate(id, tree: tree) == .stop, tree.kill(branch),
          p.stopped(id, code: 0, tree: tree, notify: { _ in }, retire: { _ in }),
          p.exit == TaskExit(.exited, code: -37), selfHandle(&p, tree: tree) == 0
        else { return false }
        var invalid: UInt8 = 0
        return p.beginCleanup(
          invalidate: { invalid |= $0 == own ? 1 : $0 == name ? 2 : 4 }, retire: { _ in })
          && invalid == 3
          && p.finishCleanup(tree: tree, notify: { _ in }) && ph.pointee.signals & 16 != 0
          && tree.remove(branch) && tree.usage(tree.root)?.footprint == 0
      }
    }
    #if arch(arm64)
      keys.erase()
      for i in bank.indices where bank[i] != 0 { return false }
    #endif
    return result
  }
}

private struct PrivateEvents: EventNamespace {
  let record: UnsafeMutablePointer<EventEndpoints>
  let table: UnsafeMutablePointer<HandleTable>
  var notified: UInt32 = 0
  mutating func withNewEvent(
    pair: Bool, _ body: (inout EventEndpoints, inout HandleTable) -> CallResult
  ) -> CallResult {
    body(&record.pointee, &table.pointee)
  }
  mutating func withEvent(
    named: UInt64,
    _ body: (borrowing EventEndpoints, borrowing HandleTable, (UnsafePointer<ObjectHeader>) -> Void)
      -> CallResult
  ) -> CallResult {
    body(record.pointee, table.pointee, { notified = $0.pointee.signals })
  }
}

private struct ProbePort: SignalPorts {
  let id: UInt64
  let port: UnsafeMutablePointer<CompletionPort>
  var wakes = 0
  mutating func withPort<R>(_ id: UInt64, _ body: (inout CompletionPort) -> R) -> R? {
    id == self.id ? body(&port.pointee) : nil
  }
  mutating func wake(port: UInt64, count: Int) { if port == id { wakes += count } }
}

private struct ProbeObserverCaller: SignalCaller {
  let table: UnsafeMutablePointer<HandleTable>
  let list: UnsafeMutablePointer<SignalObservers>
  var ports: ProbePort
  mutating func withObservers(
    source: UInt64,
    _ body: (UInt64, borrowing HandleTable, inout SignalObservers, inout ProbePort, UInt64) ->
      SignalArmResult
  ) -> SignalArmResult {
    body(10, table.pointee, &list.pointee, &ports, 17)
  }
}

private func observePeer(
  _ arena: inout Arena, ids: borrowing KoidSource, ends: inout EventEndpoints, source: UInt64,
  peer: UInt64, header: UnsafePointer<ObjectHeader>, table: UnsafeMutablePointer<HandleTable>
) -> Bool {
  let slab = arena.take(PortSlot.self, count: 2)
  let observers = arena.take(ObserverSlot.self, count: 1)
  slab.initialize(repeating: PortSlot())
  observers.initialize(repeating: ObserverSlot())
  defer {
    slab.deinitialize()
    observers.deinitialize()
  }
  guard let ph = ObjectHeader(source: ids, ownerJob: 1, kind: TarwinKind.port, maximumRights: 0),
    var port = CompletionPort(storage: slab)
  else { return false }
  var list = SignalObservers(object: header, storage: observers)
  return withUnsafePointer(to: ph) { h in
    guard case .installed(let name) = table.pointee.install(h, rights: 0) else { return false }
    defer { _ = table.pointee.close(name, retire: { _ in preconditionFailure() }) }
    return withUnsafeMutablePointer(to: &port) { p in
      withUnsafeMutablePointer(to: &list) { l in
        var gate = RegisterGate(
          calls: WaitAsyncCalls(
            context: ProbeObserverCaller(
              table: table, list: l,
              ports: ProbePort(id: h.pointee.koid, port: p))))
        let bit: UInt32 = 1 << 31
        guard
          NativeObject.waitAsync(
            peer, signals: bit, mode: .edge, port: name, key: 27,
            gate: &gate
          ).code == 0, p.pointee.available == 0
        else { return false }
        var ports = gate.calls.context.ports
        return withUnsafeMutablePointer(to: &ports) { router in
          func notify(_ target: UnsafePointer<ObjectHeader>) {
            if target == header { l.pointee.changed(at: 21, ports: &router.pointee) }
          }
          guard
            ends.signal(name: source, set: bit, clear: 0, in: table.pointee, notify: notify) == .ok,
            let packet = p.pointee.take(), packet.kind == 1, packet.key == 27,
            packet.flags == 1, packet.result0 == UInt64(bit), packet.timestamp == 21,
            router.pointee.wakes == 1,
            ends.signal(name: source, set: 0, clear: bit, in: table.pointee, notify: notify) == .ok
          else { return false }
          var cancelling: PortOperation?
          guard p.pointee.cancel(key: 27, schedule: { cancelling = $0 }) == 1, let cancelling
          else { return false }
          l.pointee.cancelled(cancelling, port: h.pointee.koid, at: 22, ports: &router.pointee)
          guard let final = p.pointee.take() else { return false }
          return final.flags == 0 && final.error == 26 && final.key == 27 && l.pointee.count == 0
        }
      }
    }
  }
}

private func eventPair(_ arena: inout Arena) -> Bool {
  let cells = arena.take(HandleCell.self, count: 3)
  let heads = arena.take(ObjectHeader.self, count: 2)
  let ids = KoidSource()
  guard var t = HandleTable(storage: cells, salt: 11) else { return false }
  defer { cells.deinitialize() }
  for i in 0..<2 {
    guard
      let h = ObjectHeader(
        source: ids, ownerJob: 1, kind: TarwinKind.eventPair,
        maximumRights: EventEndpoints.initialRights)
    else { return false }
    (heads.baseAddress! + i).initialize(to: h)
  }
  defer { heads.deinitialize() }
  guard
    var e = EventEndpoints(first: .init(heads.baseAddress!), second: .init(heads.baseAddress! + 1))
  else { return false }
  return withUnsafeMutablePointer(to: &t) { table in
    withUnsafeMutablePointer(to: &e) { record in
      var g = RegisterGate(calls: EventCalls(context: PrivateEvents(record: record, table: table)))
      let pair = NativeEvents.pair(gate: &g)
      guard pair.status == 0, heads[0].release() == .stillLive, heads[1].release() == .stillLive
      else { return false }
      defer { table.pointee.drain { h in record.pointee.destroy(h) { _ in } } }
      guard
        observePeer(
          &arena, ids: ids, ends: &record.pointee, source: pair.first, peer: pair.second,
          header: .init(heads.baseAddress! + 1), table: table)
      else { return false }
      guard NativeEvents.signal(pair.first, set: 1 << 24, clear: 0, gate: &g).status == 0,
        g.calls.context.notified == 1 << 24, heads[0].signals == 0,
        case .installed(let copy) = table.pointee.derive(pair.first, rights: 128, duplicate: true),
        table.pointee.close(pair.first, retire: { _ in preconditionFailure() }),
        heads[1].signals == 1 << 24,
        NativeEvents.signal(copy, set: 8, clear: 0, gate: &g).code == 4,
        table.pointee.close(copy, retire: { h in record.pointee.destroy(h) { _ in } })
      else { return false }
      return heads[1].signals == (1 << 24 | 4)
        && NativeEvents.signal(pair.second, set: 8, clear: 0, gate: &g).code == 27
    }
  }
}

private func exercise(_ bytes: UnsafeMutableRawBufferPointer, _ challenge: UInt64) -> Bool {
  var arena = Arena(remaining: bytes)
  guard eventPair(&arena) else { return false }
  guard intervalDemand(&arena, challenge) else { return false }
  guard jobQuota(&arena, challenge >> 1) else { return false }
  let cells = arena.take(HandleCell.self, count: 4)
  let receiverCells = arena.take(HandleCell.self, count: 4)
  let hdr = arena.take(ObjectHeader.self, count: 1).baseAddress!
  let grants = arena.take(ObjectGrant.self, count: 64)
  let sizes = arena.take(ChannelSize.self, count: 1)
  let payload = arena.take(UInt8.self, count: 64)
  let buckets = arena.take(AddressBucket.self, count: 2)
  let sleepers = arena.take(AddressSleeper.self, count: 1)
  let ops = arena.take(PortSlot.self, count: 1)
  ops.initialize(repeating: PortSlot())
  defer { ops.deinitialize() }
  for i in buckets.indices { (buckets.baseAddress! + i).initialize(to: AddressBucket()) }
  sleepers.baseAddress!.initialize(to: AddressSleeper())
  defer {
    buckets.deinitialize()
    sleepers.deinitialize()
  }
  guard let waits = AddressQueue(buckets: buckets, sleepers: sleepers, pageBytes: 4096) else {
    return false
  }
  let offset = UInt32(challenge & 0xf8)
  let key = WaitAddress(frame: challenge >> 12, offset: offset)
  let dest = WaitAddress(frame: key.frame + 1, offset: offset)
  var woken: SleepTicket?
  guard
    case .blocked(let token) = waits.arm(
      slot: 0, key: key, width: 8, expected: challenge, deadline: .max, load: { challenge },
      now: { 0 }, change: { _ in }),
    waits.requeue(from: key, wake: 0, to: dest, move: 1, change: { _ in })?.moved == 1,
    waits.wake(key, count: 1, change: { _ in }) == 0,
    waits.wake(dest, count: 1, change: { if case .ready(let t, _, _, .woken) = $0 { woken = t } })
      == 1,
    woken == token, !waits.finish(token, reason: .timeout, change: { _ in })
  else { return false }

  guard
    let obj = ObjectHeader(
      source: KoidSource(), ownerJob: 1, kind: TarwinKind.event, maximumRights: 7),
    var sender = HandleTable(storage: cells, salt: 11),
    var receiver = HandleTable(storage: receiverCells, salt: 13)
  else { return false }
  hdr.initialize(to: obj)
  sizes.baseAddress!.initialize(to: ChannelSize())
  defer {
    hdr.deinitialize(count: 1)
    sizes.deinitialize()
    cells.deinitialize()
    receiverCells.deinitialize()
  }
  guard var queue = ChannelQueue(lengths: sizes, bytes: .init(payload), grants: grants),
    case .installed(var sent) = sender.install(UnsafePointer(hdr), rights: 7),
    var port = CompletionPort(storage: ops),
    let owner = OperationHandle(process: 1, name: sent),
    let pending = port.reserve(object: hdr.pointee.koid, key: challenge, kind: 1, owner: owner),
    hdr.pointee.release() == .stillLive
  else { return false }
  var input = challenge
  var output: UInt64 = 0
  var received: UInt64 = 0
  var cancelled: PortOperation?
  guard
    withUnsafeBytes(
      of: &input,
      { raw in
        withUnsafePointer(to: &sent) {
          queue.write(
            raw, names: .init(start: $0, count: 1), from: &sender,
            invalidate: { name in
              if let source = OperationHandle(process: 1, name: name) {
                _ = port.cancel(owner: source) { cancelled = $0 }
              }
            },
            retire: { _ in })
        }
      }) == .ok, !sender.close(sent, retire: { _ in }), cancelled == pending,
    port.take() == nil, port.finish(pending, at: 1, result: { PortPacket() }) == 1,
    let packet = port.take(), packet.key == challenge, packet.error == 26
  else { return false }
  queue.closeSender()
  var size = ChannelSize()
  guard
    withUnsafeMutableBytes(
      of: &output,
      { raw in
        withUnsafeMutablePointer(to: &received) {
          queue.read(into: raw, names: .init(start: $0, count: 1), to: &receiver, size: &size)
        }
      }) == .ok, size.bytes == 8, size.handles == 1, received != sent, output == challenge
  else { return false }
  let epoch = EpochDomain()
  guard
    case .found(let observed) = receiver.reader.pin(
      received, kind: TarwinKind.event, need: 4, in: epoch)
  else { return false }
  let good = observed.rights == 7 && observed.header == UnsafePointer(hdr)
  observed.drop(retire: { _ in })
  return good
    && withUnsafeMutablePointer(to: &receiver) { table in
      withUnsafePointer(to: epoch) { ep in
        var gate = RegisterGate(calls: HandleCalls(context: LocalContext(table: table, epoch: ep)))
        let replaced = NativeHandles.replace(received, rights: 4, gate: &gate)
        guard replaced.status == 0, NativeHandles.close(received, gate: &gate).code == 2,
          NativeHandles.duplicate(replaced.first, rights: 4, gate: &gate).code == 4,
          NativeHandles.close(replaced.first, gate: &gate).status == 0,
          gate.calls.context.life.removed == replaced.first,
          gate.calls.context.life.retired == hdr.pointee.koid, let ticket = epoch.beginGracePeriod()
        else { return false }
        return epoch.finishGracePeriod(ticket)
      }
    }
}

private func intervalDemand(_ arena: inout Arena, _ id: UInt64) -> Bool {
  let members = arena.take(UInt64.self, count: 1)
  members.initialize(repeating: 0)
  defer { members.deinitialize() }
  guard var group = WorkInterval(owner: id, referenceCapacity: 100, members: members),
    group.join(id, by: id), let first = group.begin(by: id, start: 0, deadline: 100),
    group.charge(id, epoch: first, from: 0, to: 50, capacity: 100),
    group.complete(by: id, epoch: first, now: 50),
    group.begin(by: id, start: 100, deadline: 200) != nil,
    !group.complete(by: id, epoch: first, now: 150)
  else { return false }
  func point(_ capacity: UInt32, _ cost: UInt32) -> OperatingPoint {
    .init(
      offer: .init(
        online: true, features: 1, capacity: capacity, energy: cost, load: 0,
        efficiency: true, idle: true, thermalHeadroom: true, runningSiblingJob: 0,
        isolatedSiblings: true),
      hz: UInt64(capacity), ceilingHz: 100)
  }
  var choices: InlineArray<2, OperatingPoint> = [point(50, 1), point(100, 2)]
  return withUnsafeBytes(of: &choices) { bytes in
    let points = bytes.bindMemory(to: OperatingPoint.self)
    return selectOperatingPoint(
      points, required: 1, job: id, qos: SchedClass.interactive,
      demand: group.demand(id, now: 100), haveEfficiency: true) == 0
      && selectOperatingPoint(
        points, required: 1, job: id, qos: SchedClass.interactive,
        demand: group.demand(id, now: 151), haveEfficiency: true) == 1
  }
}

private typealias Output = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt16>) -> UInt
private typealias Reset = @convention(c) (UInt32, UInt, UInt, UnsafeRawPointer?) -> Void
@_cdecl("efi_main")
public func efiMain(_ image: UnsafeRawPointer?, _ system: UnsafeRawPointer?) -> UInt {
  #if arch(arm64)
    let count: UInt = 94
  #else
    let count: UInt = 2
  #endif
  // Only firmware-owned tables in this disposable EFI guest.
  guard let image, let system, let boot = FirmwareBootServices(image: image, system: system),
    let rt = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(rt, signature: 0x5652_4553_544e_5552, minimum: 112),
    let shutdown = rt.load(fromByteOffset: 104, as: Reset?.self),
    let console = system.load(fromByteOffset: 64, as: UnsafeRawPointer?.self),
    let output = console.load(fromByteOffset: 8, as: Output?.self),
    let pages = boot.reserveLoaderPages(count),
    let p = UnsafeMutableRawPointer(bitPattern: UInt(pages.base))
  else { return (1 << 63) | 3 }
  let ok = exercise(.init(start: p, count: Int(pages.length)), UInt64(UInt(bitPattern: image)))
  let freed = boot.releaseLoaderPages(pages)
  let message: StaticString =
    ok && freed ? "TARWIN-EXECUTION-PASS\r\n" : "TARWIN-EXECUTION-FAIL\r\n"
  for i in 0..<message.utf8CodeUnitCount {
    var c = (UInt16(message.utf8Start[i]), UInt16(0))
    _ = withUnsafeBytes(of: &c) { output(console, $0.bindMemory(to: UInt16.self).baseAddress!) }
  }
  shutdown(2, 0, 0, nil)
  return (1 << 63) | 3
}
