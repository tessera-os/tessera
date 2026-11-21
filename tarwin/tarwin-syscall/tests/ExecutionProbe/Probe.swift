import LibTesseraTarwin
import Tarboot
import TarwinABI
import TarwinIPCChannels
import TarwinObject
import TarwinObjectCalls
import TarwinSync
import TarwinSyncObjects
import TarwinSyscall

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
private struct RegisterGate: NativeGate {
  var calls: HandleCalls<LocalContext>
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
    var scratch = (UInt64(0), UInt64(0))
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

private func jobQuota(_ arena: inout Arena, _ limit: UInt64) -> Bool {
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
      source: ids, ownerJob: root.koid, kind: TarwinKind.job, maximumRights: 0),
    let branch = tree.create(child, under: tree.root, policy: policy),
    let process = ObjectHeader(
      source: ids, ownerJob: child.koid, kind: TarwinKind.process, maximumRights: 0),
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
        header: ph, job: branch, tree: tree, slots: slots, cells: cells, salt: 3)
    else { return false }
    defer { cells.deinitialize() }
    return withUnsafePointer(to: thread) { th in
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
          p.gate(id, tree: tree) == .dispatch,
          case .installed(let name)? = p.withHandles(tree: tree, { $0.install(th, rights: 0) }),
          tree.setFrozen(true, job: tree.root), p.gate(id, tree: tree) == .hold,
          tree.kill(branch), p.gate(id, tree: tree) == .stop,
          p.stopped(id, code: 0, tree: tree, notify: { _ in }, retire: { _ in }),
          p.exit?.reason == .jobKilled
        else { return false }
        var invalid: UInt64 = 0
        return p.beginCleanup(invalidate: { invalid = $0 }, retire: { _ in }) && invalid == name
          && p.finishCleanup(tree: tree, notify: { _ in }) && ph.pointee.signals & 16 != 0
          && tree.remove(branch) && tree.usage(tree.root)?.footprint == 0
      }
    }
  }
}

private func exercise(_ bytes: UnsafeMutableRawBufferPointer, _ challenge: UInt64) -> Bool {
  var arena = Arena(remaining: bytes)
  guard jobQuota(&arena, challenge >> 1) else { return false }
  let cells = arena.take(HandleCell.self, count: 4)
  let receiverCells = arena.take(HandleCell.self, count: 4)
  let hdr = arena.take(ObjectHeader.self, count: 1).baseAddress!
  let grants = arena.take(ObjectGrant.self, count: 64)
  let sizes = arena.take(ChannelSize.self, count: 1)
  let payload = arena.take(UInt8.self, count: 64)
  let buckets = arena.take(AddressBucket.self, count: 2)
  let sleepers = arena.take(AddressSleeper.self, count: 1)
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
    hdr.pointee.release() == .stillLive
  else { return false }
  var input = challenge
  var output: UInt64 = 0
  var received: UInt64 = 0
  guard
    withUnsafeBytes(
      of: &input,
      { raw in
        withUnsafePointer(to: &sent) {
          queue.write(raw, names: .init(start: $0, count: 1), from: &sender, retire: { _ in })
        }
      }) == .ok, !sender.close(sent, retire: { _ in })
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

private typealias Output = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt16>) -> UInt
private typealias Reset = @convention(c) (UInt32, UInt, UInt, UnsafeRawPointer?) -> Void
@_cdecl("efi_main")
public func efiMain(_ image: UnsafeRawPointer?, _ system: UnsafeRawPointer?) -> UInt {
  // Only firmware-owned tables in this disposable EFI guest.
  guard let image, let system, let boot = FirmwareBootServices(image: image, system: system),
    let rt = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(rt, signature: 0x5652_4553_544e_5552, minimum: 112),
    let shutdown = rt.load(fromByteOffset: 104, as: Reset?.self),
    let console = system.load(fromByteOffset: 64, as: UnsafeRawPointer?.self),
    let output = console.load(fromByteOffset: 8, as: Output?.self),
    let pages = boot.reserveLoaderPages(2),
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
