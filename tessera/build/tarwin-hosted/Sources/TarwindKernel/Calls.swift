import Foundation
import TarwinABI
import TarwinChannelCalls
import TarwinIPCChannels
import TarwinKernelCalls
import TarwinObject
import TarwinObjectCalls
import TarwinSync
import TarwinSyncCalls
import TarwinSyscall

private func failure(_ code: UInt32) -> CallResult { CallResult(status: syscallStatus(code, 1)) }

struct Retirement: HandleRetirement {
  let state: KernelState
  let process: TarwindProcessID
  mutating func retire(_ header: UnsafePointer<ObjectHeader>) { state.retired.append(header) }
  mutating func invalidate(_ name: UInt64) { state.invalidate(name, process: process) }
}

final class CallContext: HandleCallContext, EventNamespace, ChannelCreateContext,
  ChannelNamespace, ChannelUserInput, ChannelUserOutput, TimeCallClock, WaitQueueContext,
  ObjectWaitContext {
  let state: KernelState
  let process: KernelProcess
  let id: TarwindProcessID
  let threadSlot: Int
  var blocked: TarwindContinuationID?
  var waitObject: UnsafePointer<ObjectHeader>?
  var waitMask: UInt32 = 0
  var waitName: UInt64 = 0
  var userRange: Range<UInt64> { 1..<UInt64.max }
  var waits: UnsafePointer<AddressQueue> { UnsafePointer(state.waits) }
  var objectWaits: UnsafePointer<AddressQueue> { UnsafePointer(state.objectWaits) }
  init(state: KernelState, process: KernelProcess, id: TarwindProcessID, slot: Int) {
    self.state = state; self.process = process; self.id = id; threadSlot = slot
  }
  func withWriter<R>(_ body: (inout HandleTable, inout Retirement) -> R) -> R {
    var retirement = Retirement(state: state, process: id)
    return body(&process.table.pointee, &retirement)
  }
  func withRead<R>(_ body: (HandleReadView, inout Retirement) -> R) -> R {
    var retirement = Retirement(state: state, process: id)
    return body(process.table.pointee.reader, &retirement)
  }
  func readWords(from address: UInt64, into dest: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    guard address & 7 == 0, let bytes = process.span(address, count: UInt64(dest.count) * 8) else { return false }
    for i in dest.indices { dest[i] = bytes.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) }
    return true
  }
  func writeWords(to address: UInt64, from words: UnsafeBufferPointer<UInt64>) -> Bool {
    guard address & 7 == 0, let bytes = process.span(address, count: UInt64(words.count) * 8) else { return false }
    for i in words.indices { bytes.storeBytes(of: words[i], toByteOffset: i * 8, as: UInt64.self) }
    return true
  }
  func newHeader(kind: UInt32, rights: UInt64) -> UnsafeMutablePointer<ObjectHeader>? {
    guard state.headers.count < 1024,
      let header = ObjectHeader(source: state.source, ownerJob: 1, kind: kind, maximumRights: rights) else { return nil }
    let stored = state.arena.store(consume header)
    state.headers.append(stored)
    return stored
  }
  func dropCreator(_ header: UnsafeMutablePointer<ObjectHeader>) {
    if header.pointee.release() == .destroy { state.retired.append(UnsafePointer(header)) }
  }
  func withNewEvent(pair: Bool, _ body: (inout EventEndpoints, inout HandleTable) -> CallResult) -> CallResult {
    let kind = pair ? TarwinKind.eventPair : TarwinKind.event
    guard let a = newHeader(kind: kind, rights: EventEndpoints.initialRights) else { return failure(33) }
    let b: UnsafeMutablePointer<ObjectHeader>?
    if pair {
      guard let second = newHeader(kind: kind, rights: EventEndpoints.initialRights) else {
        dropCreator(a); return failure(33)
      }
      b = second
    } else { b = nil }
    let endpoints = state.arena.store(EventEndpoints(first: UnsafePointer(a), second: b.map { UnsafePointer($0) })!)
    state.eventObjects[a.pointee.koid] = endpoints
    if let b { state.eventObjects[b.pointee.koid] = endpoints }
    let result = body(&endpoints.pointee, &process.table.pointee)
    dropCreator(a); if let b { dropCreator(b) }
    return result
  }
  func withEvent(named name: UInt64,
    _ body: (borrowing EventEndpoints, borrowing HandleTable, (UnsafePointer<ObjectHeader>) -> Void) -> CallResult) -> CallResult {
    switch process.table.pointee.reader.pinWithinEpoch(name, kind: 0, need: 0) {
    case .invalidHandle: return failure(2)
    case .wrongType: return failure(3)
    case .accessDenied: return failure(4)
    case .found(let grant):
      let object = grant.header
      grant.drop { state.retired.append($0) }
      guard object.pointee.kind == TarwinKind.event || object.pointee.kind == TarwinKind.eventPair else { return failure(3) }
      guard let endpoints = state.eventObjects[object.pointee.koid] else { return failure(2) }
      return body(endpoints.pointee, process.table.pointee, { self.state.notify($0) })
    }
  }
  func queue() -> ChannelQueue {
    let lengths = state.arena.initialized(ChannelSize(), count: 8)
    let bytes = state.arena.raw(count: 65536)
    let grants = state.arena.uninitialized(ObjectGrant.self, count: 8 * 64)
    return ChannelQueue(lengths: lengths, bytes: bytes, grants: grants)!
  }
  func withNewChannel(_ body: (UnsafePointer<ObjectHeader>, UnsafePointer<ObjectHeader>, inout HandleTable) -> CallResult) -> CallResult {
    guard let a = newHeader(kind: TarwinKind.channel, rights: 0x7cf) else { return failure(33) }
    guard let b = newHeader(kind: TarwinKind.channel, rights: 0x7cf) else { dropCreator(a); return failure(33) }
    let pair = state.arena.store(ChannelPair(a: UnsafePointer(a), b: UnsafePointer(b), toA: queue(), toB: queue())!)
    state.channelObjects[a.pointee.koid] = pair; state.channelObjects[b.pointee.koid] = pair
    let result = body(UnsafePointer(a), UnsafePointer(b), &process.table.pointee)
    dropCreator(a); dropCreator(b)
    return result
  }
  func withPair(named name: UInt64, _ body: (inout ChannelPair, inout HandleTable) -> CallResult) -> CallResult {
    switch process.table.pointee.reader.pinWithinEpoch(name, kind: TarwinKind.channel, need: 0) {
    case .invalidHandle: return failure(2)
    case .wrongType: return failure(3)
    case .accessDenied: return failure(4)
    case .found(let grant):
      let header = grant.header
      grant.drop { state.retired.append($0) }
      guard let pair = state.channelObjects[header.pointee.koid] else { return failure(2) }
      let result = body(&pair.pointee, &process.table.pointee)
      for pointer in state.headers where state.channelObjects[pointer.pointee.koid] == pair {
        state.notify(UnsafePointer(pointer))
      }
      return result
    }
  }
  func withCaptured(names: Range<UInt64>, bytes: Range<UInt64>?,
    _ body: (UnsafeBufferPointer<UInt64>, UnsafeRawBufferPointer?) -> CallResult) -> CallResult? {
    guard let nameBytes = process.span(names.lowerBound, count: names.count64), names.count64 % 8 == 0 else { return nil }
    var copy: [UInt64] = []
    for i in stride(from: 0, to: nameBytes.count, by: 8) { copy.append(nameBytes.loadUnaligned(fromByteOffset: i, as: UInt64.self)) }
    guard let bytes, let payload = process.span(bytes.lowerBound, count: bytes.count64) else {
      return copy.withUnsafeBufferPointer { body($0, nil) }
    }
    let snapshot = Array(payload)
    return copy.withUnsafeBufferPointer { handles in snapshot.withUnsafeBytes { body(handles, $0) } }
  }
  func withWritable(bytes: Range<UInt64>, names: Range<UInt64>,
    _ body: (UnsafeMutableRawBufferPointer, UnsafeMutableBufferPointer<UInt64>) -> CallResult) -> CallResult? {
    guard let output = process.span(bytes.lowerBound, count: bytes.count64),
      let handles = process.span(names.lowerBound, count: names.count64) else { return nil }
    return body(output, handles.bindMemory(to: UInt64.self))
  }
  func read(clock: UInt32) -> UInt64? {
    let time = state.now()
    switch clock { case 0: return time.monotonic; case 1: return time.boot; case 2: return time.utc; default: return nil }
  }
  struct Word: PinnedWaitWord {
    let bytes: UnsafeMutableRawBufferPointer
    let physical: WaitAddress
    func load() -> UInt64? {
      bytes.count == 4 ? UInt64(bytes.loadUnaligned(as: UInt32.self)) : bytes.loadUnaligned(as: UInt64.self)
    }
  }
  func withReadable<R>(_ address: UInt64, width: UInt32, _ body: (Word) -> R) -> R? {
    guard let span = process.span(address, count: UInt64(width)) else { return nil }
    return body(Word(bytes: span, physical: WaitAddress(frame: address / 4096, offset: UInt32(address % 4096))))
  }
  func critical<R>(_ body: () -> R) -> R { body() }
  func monotonic() -> UInt64 { state.now().monotonic }
  func owner(of: Word, ifEqualTo: UInt32) -> UInt64 { 0 }
  func change(_ event: AddressChange, deadline: UInt64) {
    if case .block(let ticket, _, _) = event {
      state.nextContinuation += 1
      let continuation = TarwindContinuationID(value: state.nextContinuation)
      let pending = PendingCall(id: continuation, process: id, ticket: ticket,
        object: waitObject, mask: waitMask, name: waitName)
      if deadline != .max {
        pending.timer = state.timers.pointee.arm(deadline: deadline, at: state.now(), tolerance: .strict, cookie: continuation.value)
      }
      state.pending[continuation] = pending
      blocked = continuation
    } else { state.changed(event) }
  }
  func withWaitObject(name: UInt64, mask: UInt32,
    _ body: (UnsafePointer<ObjectHeader>) -> SplitWaitResult) -> SplitWaitResult {
    switch process.table.pointee.reader.pinWithinEpoch(name, kind: 0, need: 128) {
    case .invalidHandle: return .completed(failure(2))
    case .wrongType: return .completed(failure(3))
    case .accessDenied: return .completed(failure(4))
    case .found(let grant):
      let object = grant.header
      waitObject = object; waitMask = mask; waitName = name
      let result = body(object)
      if case .blocked = result {
        guard object.pointee.retainIfLive() else { preconditionFailure("lost pinned object") }
      }
      grant.drop { state.retired.append($0) }
      return result
    }
  }
  func observed(_ ticket: SleepTicket) -> UInt32 { waitObject?.pointee.signals ?? 0 }
}

private extension Range where Bound == UInt64 {
  var count64: UInt64 { upperBound - lowerBound }
}

struct KernelCalls: CallProvider {
  let context: CallContext
  func argumentCount(for n: UInt64) -> UInt32? {
    HandleCalls(context: context).argumentCount(for: n)
      ?? EventCalls(context: context).argumentCount(for: n)
      ?? ChannelCreateCalls(context: context).argumentCount(for: n)
      ?? ChannelWriteCalls(space: context, memory: context, lifecycle: Retirement(state: context.state, process: context.id)).argumentCount(for: n)
      ?? ChannelReceiveCalls(space: context, memory: context).argumentCount(for: n)
      ?? TimeCalls(clock: context).argumentCount(for: n)
      ?? ObjectWaitCalls(context: context).argumentCount(for: n)
      ?? SplitWaitCalls(context: context).argumentCount(for: n)
  }
  func copyUserWords(from: UInt64, into: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    context.readWords(from: from, into: into)
  }
  func invoke(number n: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    var handles = HandleCalls(context: context)
    if handles.argumentCount(for: n) != nil { return handles.invoke(number: n, words: words) }
    var events = EventCalls(context: context)
    if events.argumentCount(for: n) != nil { return events.invoke(number: n, words: words) }
    var create = ChannelCreateCalls(context: context)
    if create.argumentCount(for: n) != nil { return create.invoke(number: n, words: words) }
    var write = ChannelWriteCalls(space: context, memory: context, lifecycle: Retirement(state: context.state, process: context.id))
    if write.argumentCount(for: n) != nil { return write.invoke(number: n, words: words) }
    var read = ChannelReceiveCalls(space: context, memory: context)
    if read.argumentCount(for: n) != nil { return read.invoke(number: n, words: words) }
    let time = TimeCalls(clock: context)
    if time.argumentCount(for: n) != nil { return time.invoke(number: n, words: words) }
    let result: SplitWaitResult
    if n == TarwinCall.objectWait { result = ObjectWaitCalls(context: context).begin(number: n, words: words) }
    else { result = SplitWaitCalls(context: context).begin(number: n, words: words) }
    switch result {
    case .completed(let result): return result
    case .blocked: return CallResult() // The gate publishes the saved ticket, never this placeholder.
    }
  }
}

extension KernelState {
  func call(process id: TarwindProcessID, registers: inout TarwinCallRegisters) -> CallOutcome {
    lock.lock()
    defer { lock.unlock() }
    func finish(_ result: CallResult) -> CallOutcome { registers.complete(result); return .completed(result) }
    guard !stopped, let process = processes[id] else { return finish(failure(2)) }
    guard let slot = (0..<64).first(where: { !usedSlots.contains($0) }),
      nextContinuation < UInt64.max, pending.count + completions.count < 4096 else { return finish(failure(33)) }
    usedSlots.insert(slot)
    let context = CallContext(state: self, process: process, id: id, slot: slot)
    var provider = KernelCalls(context: context)
    var words = [UInt64](repeating: 0, count: 16)
    let result = words.withUnsafeMutableBufferPointer {
      dispatchCall(isa: .aarch64, savedPC: 0x1004, libraryCode: 0x1000..<0x1010,
        userRange: context.userRange, number: registers.number, registers: registers.arguments,
        scratch: $0, provider: &provider)
    }
    drainRetired()
    if let continuation = context.blocked { return .blocked(continuation) }
    usedSlots.remove(slot)
    switch result {
    case .returned(let result): return finish(result)
    case .stopCaller, .terminateBadOrigin: return finish(failure(23))
    }
  }
}
