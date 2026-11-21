import CHostDarwin
import Darwin
import Foundation

/// Tarwin scheduling intent translated to host QoS or time constraints.
public enum HostSchedulingPolicy: Sendable {
  case interactive, realtime(periodNanos: UInt64, computationNanos: UInt64), `default`, background

  func apply(to thread: pthread_t, state: inout th_scheduling_state) throws {
    let result: Int32
    switch self {
    case .interactive: result = th_apply_policy(thread, &state, 0, 0, 0)
    case .realtime(let period, let computation):
      guard computation > 0, computation <= period else { throw HostError("realtime budget", code: EINVAL) }
      result = th_apply_policy(thread, &state, 1, period, computation)
    case .default: result = th_apply_policy(thread, &state, 2, 0, 0)
    case .background: result = th_apply_policy(thread, &state, 3, 0, 0)
    }
    guard result == 0 else { throw HostError("thread scheduling policy", code: result) }
  }
}

private final class WorkerState: @unchecked Sendable {
  let condition = NSCondition()
  let name: String
  let policy: HostSchedulingPolicy
  let body: @Sendable () -> Void
  var ready = false
  var finished = false
  var error: (any Error)?
  var scheduling = th_scheduling_state()
  init(name: String, policy: HostSchedulingPolicy, body: @escaping @Sendable () -> Void) {
    self.name = name
    self.policy = policy
    self.body = body
  }
  func run() {
    pthread_setname_np(String(name.prefix(63)))
    condition.lock()
    do {
      let result = th_initialize_worker()
      guard result == 0 else { throw HostError("worker QoS", code: result) }
      try policy.apply(to: pthread_self(), state: &scheduling)
    } catch { self.error = error }
    ready = true
    condition.broadcast()
    let allowed = error == nil
    condition.unlock()
    if allowed { body() }
    condition.lock()
    th_release_policy(&scheduling)
    finished = true
    condition.broadcast()
    condition.unlock()
  }
}

/// A running pthread whose body owns its lifetime independently of this handle.
public final class HostThread: @unchecked Sendable {
  private let thread: pthread_t
  private let state: WorkerState

  fileprivate init(name: String, policy: HostSchedulingPolicy, body: @escaping @Sendable () -> Void) throws {
    let state = WorkerState(name: name, policy: policy, body: body)
    let context = Unmanaged.passRetained(state).toOpaque()
    var thread: pthread_t?
    let result = pthread_create(&thread, nil, { context in
      Unmanaged<WorkerState>.fromOpaque(context).takeRetainedValue().run()
      return nil
    }, context)
    guard result == 0, let thread else {
      Unmanaged<WorkerState>.fromOpaque(context).release()
      throw HostError("pthread_create", code: result)
    }
    self.thread = thread
    self.state = state
    pthread_detach(thread)
    state.condition.lock()
    while !state.ready { state.condition.wait() }
    let error = state.error
    state.condition.unlock()
    if let error { throw error }
  }

  /// Applies policy to a live worker, throwing if XNU refuses or the worker has exited.
  public func apply(_ policy: HostSchedulingPolicy) throws {
    state.condition.lock()
    defer { state.condition.unlock() }
    guard !state.finished else { throw HostError("worker exited", code: ESRCH) }
    try policy.apply(to: thread, state: &state.scheduling)
  }

  /// Waits for body completion without retaining a joinable pthread resource.
  public func waitUntilFinished() {
    state.condition.lock()
    defer { state.condition.unlock() }
    while !state.finished { state.condition.wait() }
  }
}

/// Host CPU topology and explicitly managed worker creation.
public struct HostCPU: Sendable {
  /// Creates a topology accessor without allocating workers.
  public init() {}
  /// Online logical processors available to the host.
  public var logicalCount: Int { count("hw.logicalcpu") }
  /// Performance-core logical processors, falling back to the total on uniform hosts.
  public var performanceCount: Int { max(1, count("hw.perflevel0.logicalcpu", fallback: logicalCount)) }
  /// Starts a named worker after successfully applying its initial policy.
  public func startWorker(name: String, qos: HostSchedulingPolicy = .default,
    body: @escaping @Sendable () -> Void) throws -> HostThread {
    try HostThread(name: name, policy: qos, body: body)
  }
  private func count(_ name: String, fallback: Int = 1) -> Int {
    var value: Int32 = 0
    var size = MemoryLayout.size(ofValue: value)
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? max(1, Int(value)) : fallback
  }
}
