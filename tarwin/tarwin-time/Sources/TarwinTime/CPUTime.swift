/// One lifetime per thread KOID. These clocks measure the executing thread,
/// not the scheduling context that donated its budget.
public struct ThreadCPUTime: ~Copyable {
  public let id, process: UInt64
  fileprivate var completed: UInt64 = 0
  fileprivate var lane: Int?

  public init?(id: UInt64, process: UInt64) {
    guard id != 0, process != 0 else { return nil }
    self.id = id
    self.process = process
  }
}

/// Private, initialized storage, one lane per logical CPU available to the process.
public struct CPUTimeLane {
  fileprivate var completed: UInt64 = 0, sample: UInt64 = 0
  fileprivate var thread: UInt64 = 0, epoch: UInt64 = 0
  public init() {}
}

public struct CPUTimeRun {
  fileprivate let process, thread, epoch: UInt64
  fileprivate let cpu: Int
}

/// Scheduler serializes each transition and snapshot. All counters have the
/// same invariant frequency; their origins may differ. Stop active runs
/// before idle, parking or suspend. Counter samples for a lane must remain
/// nondecreasing across those transitions.
/// KOIDs are kernel-owned and not reused. The lane buffer is exclusively
/// borrowed for the full lifetime of this object.
public struct ProcessCPUTime: ~Copyable {
  private let lanes: UnsafeMutableBufferPointer<CPUTimeLane>
  private let id, frequency: UInt64

  public init?(id: UInt64, frequency: UInt64, lanes: UnsafeMutableBufferPointer<CPUTimeLane>) {
    guard id != 0, frequency != 0, !lanes.isEmpty else { return nil }
    self.id = id
    self.frequency = frequency
    self.lanes = lanes
    for i in lanes.indices { lanes[i] = CPUTimeLane() }
  }

  /// Commit at an actual execution boundary, not when a thread becomes ready.
  public mutating func begin(_ thread: inout ThreadCPUTime, on cpu: Int, counter: UInt64) -> CPUTimeRun? {
    guard thread.process == id, thread.lane == nil, lanes.indices.contains(cpu),
      lanes[cpu].thread == 0, lanes[cpu].epoch != .max, counter >= lanes[cpu].sample else { return nil }
    lanes[cpu].epoch += 1
    lanes[cpu].sample = counter
    lanes[cpu].thread = thread.id
    thread.lane = cpu
    return CPUTimeRun(process: id, thread: thread.id, epoch: lanes[cpu].epoch, cpu: cpu)
  }

  public mutating func end(_ run: CPUTimeRun, thread: inout ThreadCPUTime, counter: UInt64) -> Bool {
    let cpu = run.cpu
    guard run.process == id, thread.process == id, thread.id == run.thread,
      thread.lane == cpu, lanes.indices.contains(cpu), lanes[cpu].thread == thread.id,
      run.epoch == lanes[cpu].epoch, counter >= lanes[cpu].sample else { return false }
    let delta = counter - lanes[cpu].sample
    guard delta <= .max - thread.completed, delta <= .max - lanes[cpu].completed else { return false }
    lanes[cpu].completed += delta
    lanes[cpu].sample = counter
    lanes[cpu].thread = 0
    thread.completed += delta
    thread.lane = nil
    return true
  }

  private func delta(on cpu: Int, sample: (Int) -> UInt64?) -> UInt64? {
    if lanes[cpu].thread == 0 { return 0 }
    guard let now = sample(cpu), now >= lanes[cpu].sample else { return nil }
    return now - lanes[cpu].sample
  }

  /// Samples are from the indicated CPU under the same snapshot; never
  /// subtract one CPU's counter from another. Convert only after summing ticks.
  public func threadNanoseconds(_ thread: borrowing ThreadCPUTime, sample: (Int) -> UInt64?) -> UInt64? {
    guard thread.process == id else { return nil }
    var total = thread.completed
    if let cpu = thread.lane {
      guard lanes.indices.contains(cpu), lanes[cpu].thread == thread.id,
        let live = delta(on: cpu, sample: sample), live <= .max - total else { return nil }
      total += live
    }
    return ns(total)
  }

  public func processNanoseconds(sample: (Int) -> UInt64?) -> UInt64? {
    var total: UInt64 = 0
    for cpu in lanes.indices {
      guard let live = delta(on: cpu, sample: sample), live <= .max - total else { return nil }
      total += live
      guard lanes[cpu].completed <= .max - total else { return nil }
      total += lanes[cpu].completed
    }
    return ns(total)
  }

  private func ns(_ ticks: UInt64) -> UInt64? {
    let value = counterDuration(ticks, frequency: frequency)
    return value.valid ? value.ns : nil
  }
}
