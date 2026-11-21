public enum ExitReason: UInt32, Sendable { case exited, killed, crashed, jobKilled, outOfMemory }
public struct TaskExit: Equatable, Sendable {
  public let reason: ExitReason
  public let code: Int64
  public init(_ reason: ExitReason, code: Int64) {
    self.reason = reason
    self.code = code
  }
}
public enum ThreadPhase: UInt32 { case created, runnable, blocked, terminated }
public enum ThreadGate: Equatable { case dispatch, hold, stop }

/// Store beside the thread object at a stable kernel address. The object
/// owns its header and this state for the entire lifetime of its handles.
public struct ThreadExecution: ~Copyable {
  public let process: ProcessKey
  public let header: UnsafePointer<ObjectHeader>
  public private(set) var phase: ThreadPhase = .created
  public private(set) var exitCode: Int64 = 0
  public private(set) var requestedQos: UInt8 = 0
  fileprivate var attached = false
  public init?(header: UnsafePointer<ObjectHeader>, process: ProcessKey, job: JobKey) {
    guard header.pointee.kind == TarwinKind.thread, header.pointee.ownerJob == job.id else {
      return nil
    }
    self.header = header
    self.process = process
  }
  fileprivate mutating func join(qos: UInt8) {
    attached = true
    requestedQos = qos
  }
  fileprivate mutating func set(_ state: ThreadPhase) { phase = state }
  fileprivate mutating func finish(_ code: Int64) {
    phase = .terminated
    exitCode = code
    attached = false
  }
}

public struct ThreadSlot {
  fileprivate var thread: UnsafeMutablePointer<ThreadExecution>?
  public init() { thread = nil }
}
public enum ThreadAdmission: Equatable { case added, invalid, denied, quota, noSpace }
public enum ProcessPhase: Equatable {
  case created, running, suspended, stopping, cleaning, terminated
}

/// Task lifecycle under the kernel task lock. Take the tree lock before the
/// task lock when an operation needs both. The caller keeps the process
/// record, header and slot array stable until completion. A joined thread
/// is independently pinned until the switch path acknowledges it has stopped.
public struct ProcessExecution: ~Copyable {
  public let member: ProcessKey
  public let job: JobKey
  public let header: UnsafePointer<ObjectHeader>
  private let slots: UnsafeMutableBufferPointer<ThreadSlot>
  private var handles: HandleTable
  public private(set) var threadCount: UInt32 = 0
  public private(set) var exit: TaskExit?
  private var started = false, suspended = false, cleaning = false, finished = false
  public init?(
    header: UnsafePointer<ObjectHeader>, job: JobKey, tree: borrowing JobTree,
    slots: UnsafeMutableBufferPointer<ThreadSlot>, cells: UnsafeMutableBufferPointer<HandleCell>,
    salt: UInt8
  ) {
    guard !slots.isEmpty, let policy = tree.policy(job), cells.count > 0,
      cells.count <= Int(policy.handlesPerProcess)
    else { return nil }
    for i in slots.indices where slots[i].thread != nil { return nil }
    guard let member = tree.attach(header.pointee, to: job) else { return nil }
    guard let table = HandleTable(storage: cells, salt: salt) else {
      _ = tree.detach(member)
      return nil
    }
    handles = table
    self.header = header
    self.job = job
    self.member = member
    self.slots = slots
  }
  public var phase: ProcessPhase {
    if finished { return .terminated }
    if cleaning { return .cleaning }
    if exit != nil { return .stopping }
    if suspended { return .suspended }
    return started ? .running : .created
  }
  private func thread(_ id: UInt64) -> UnsafeMutablePointer<ThreadExecution>? {
    for i in slots.indices {
      if let t = slots[i].thread, t.pointee.header.pointee.koid == id { return t }
    }
    return nil
  }
  /// Call under the process handle writer lock. At exit this gate closes to
  /// all writers; epoch-pinned readers may finish independently.
  public mutating func withHandles<R>(tree: borrowing JobTree, _ body: (inout HandleTable) -> R)
    -> R?
  {
    guard exit == nil, tree.returnGate(member) != .terminate, let policy = tree.policy(job) else {
      return nil
    }
    handles.tighten(to: policy.handlesPerProcess)
    return body(&handles)
  }
  public var handleReader: HandleReadView { handles.reader }
  /// Privilege/stack/TLS validation and private stack allocation must succeed
  /// before join. A successful join never makes the thread runnable on its own.
  public mutating func join(
    _ thread: UnsafeMutablePointer<ThreadExecution>, qos: UInt8,
    realtimeEntitled: Bool, tree: borrowing JobTree
  ) -> ThreadAdmission {
    guard exit == nil, tree.returnGate(member) != .terminate, let policy = tree.policy(job),
      thread.pointee.process == member, thread.pointee.header.pointee.ownerJob == job.id,
      !thread.pointee.attached, thread.pointee.phase == .created, qos <= 5
    else { return .invalid }
    guard qos <= policy.maxQos, qos != 5 || realtimeEntitled else { return .denied }
    guard threadCount < policy.threadsPerProcess else { return .quota }
    var free: Int?
    let header = thread.pointee.header
    for i in slots.indices {
      if let t = slots[i].thread {
        if t.pointee.header == header { return .invalid }
      } else if free == nil {
        free = i
      }
    }
    guard let free else { return .noSpace }
    guard header.pointee.retainIfLive() else { return .invalid }
    slots[free].thread = thread
    thread.pointee.join(qos: qos)
    threadCount += 1
    return .added
  }
  public mutating func start(_ id: UInt64, tree: borrowing JobTree) -> Bool {
    guard exit == nil, tree.returnGate(member) != .terminate, let t = thread(id),
      t.pointee.phase == .created
    else { return false }
    t.pointee.set(.runnable)
    started = true
    return true
  }
  public mutating func setBlocked(_ blocked: Bool, id: UInt64) -> Bool {
    guard exit == nil, let t = thread(id), t.pointee.phase == (blocked ? .runnable : .blocked)
    else { return false }
    t.pointee.set(blocked ? .blocked : .runnable)
    return true
  }
  public mutating func setSuspended(_ flag: Bool) -> Bool {
    guard exit == nil else { return false }
    suspended = flag
    return true
  }
  /// Recheck on every runnable transition and immediately before user return;
  /// thaw/resume never erase an unrelated block or start a newly created thread.
  public func gate(_ id: UInt64, tree: borrowing JobTree) -> ThreadGate {
    guard exit == nil, let t = thread(id) else { return .stop }
    switch tree.returnGate(member) {
    case .terminate: return .stop
    case .frozen: return .hold
    case .run: return !suspended && t.pointee.phase == .runnable ? .dispatch : .hold
    }
  }
  public mutating func requestExit(
    _ cause: TaskExit, tree: borrowing JobTree, stop: (UInt64) -> Void
  ) -> Bool {
    guard exit == nil else { return false }
    exit = tree.returnGate(member) == .terminate ? TaskExit(.jobKilled, code: 0) : cause
    for i in slots.indices { if let t = slots[i].thread { stop(t.pointee.header.pointee.koid) } }
    return true
  }
  /// Call after the outgoing CPU stopped using the thread's stacks. Hold
  /// the thread observer lock across publication and non-reentrant notify.
  public mutating func stopped(
    _ id: UInt64, code: Int64, tree: borrowing JobTree,
    notify: (UnsafePointer<ObjectHeader>) -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    for i in slots.indices {
      guard let t = slots[i].thread, t.pointee.header.pointee.koid == id else { continue }
      let h = t.pointee.header
      t.pointee.finish(code)
      slots[i].thread = nil
      threadCount -= 1
      _ = h.pointee.updateSignals(clear: 0, set: 1 << 4)
      notify(h)
      if h.pointee.release() == .destroy { retire(h) }
      if threadCount == 0 && exit == nil {
        exit =
          tree.returnGate(member) == .terminate
          ? TaskExit(.jobKilled, code: 0) : TaskExit(.exited, code: code)
      }
      return true
    }
    return false
  }
  /// Hold the table writer lock. Callbacks enqueue cancellation/retirement
  /// without sleeping. One worker then waits for operations and read epochs
  /// outside locks before freeing table storage and releasing the address space.
  public mutating func beginCleanup(
    invalidate: (UInt64) -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard threadCount == 0, exit != nil, !cleaning, !finished else { return false }
    cleaning = true
    handles.drain(invalidate: invalidate, retire: retire)
    return true
  }
  /// As in stopped(), hold the process observer lock across this call.
  public mutating func finishCleanup(
    tree: borrowing JobTree, notify: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard cleaning, !finished, tree.detach(member) else { return false }
    finished = true
    cleaning = false
    _ = header.pointee.updateSignals(clear: 0, set: 1 << 4)
    notify(header)
    return true
  }
}
