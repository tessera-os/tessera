/// Normalized kernel policy. The ABI decoder resolves "inherit" before
/// constructing this value. Larger QoS, band and I/O ranks are more privileged.
public struct JobLimits: Equatable, Sendable {
  public var processes: UInt32
  public var threadsPerProcess: UInt32
  public var handlesPerProcess: UInt32
  public var footprint: UInt64
  public var cpuShare: UInt32
  public var maxQos: UInt8
  public var jetsamBand: UInt8
  public var ioRank: UInt8
  public var entitlements: UInt64
  public var denials: UInt32
  public var killOnClose: Bool

  public init(
    processes: UInt32, threadsPerProcess: UInt32, handlesPerProcess: UInt32,
    footprint: UInt64, cpuShare: UInt32, maxQos: UInt8, jetsamBand: UInt8,
    ioRank: UInt8, entitlements: UInt64, denials: UInt32, killOnClose: Bool
  ) {
    self.processes = processes
    self.threadsPerProcess = threadsPerProcess
    self.handlesPerProcess = handlesPerProcess
    self.footprint = footprint
    self.cpuShare = cpuShare
    self.maxQos = maxQos
    self.jetsamBand = jetsamBand
    self.ioRank = ioRank
    self.entitlements = entitlements
    self.denials = denials
    self.killOnClose = killOnClose
  }
  fileprivate var valid: Bool {
    handlesPerProcess <= HandleLayout.maximumSlots && maxQos <= 5 && jetsamBand <= 6
      && denials & ~7 == 0
  }
  fileprivate func bounded(by other: Self) -> Self {
    Self(
      processes: min(processes, other.processes),
      threadsPerProcess: min(threadsPerProcess, other.threadsPerProcess),
      handlesPerProcess: min(handlesPerProcess, other.handlesPerProcess),
      footprint: min(footprint, other.footprint),
      cpuShare: min(cpuShare, other.cpuShare), maxQos: min(maxQos, other.maxQos),
      jetsamBand: min(jetsamBand, other.jetsamBand), ioRank: min(ioRank, other.ioRank),
      entitlements: entitlements & other.entitlements, denials: denials | other.denials,
      killOnClose: killOnClose || other.killOnClose)
  }
}

public struct JobKey: Equatable {
  fileprivate let slot: Int
  fileprivate let generation: UInt64
  public let id: UInt64
}
public struct ProcessKey: Equatable {
  fileprivate let slot: Int
  fileprivate let generation: UInt64
  public let id: UInt64
}
public struct JobUsage: Equatable {
  public fileprivate(set) var processes: UInt32 = 0
  public fileprivate(set) var footprint: UInt64 = 0
}
public enum ReturnGate: Equatable { case run, frozen, terminate }

public struct JobNode {
  fileprivate var generation: UInt64 = 0
  fileprivate var id: UInt64 = 0, parent: Int? = nil, limits: JobLimits? = nil
  fileprivate var usage = JobUsage(), frozen = false, killed = false
  public init() {}
}
public struct JobMember {
  fileprivate var generation: UInt64 = 0
  fileprivate var id: UInt64 = 0, job = 0, footprint: UInt64 = 0
  public init() {}
}

/// Call under the job-tree lock; the caller owns the slots, initialized empty,
/// and keeps each registered kernel object alive until removal. No callbacks or
/// allocation occur during a charge. Process teardown must detach exactly once.
public struct JobTree: ~Copyable {
  private let jobs: UnsafeMutableBufferPointer<JobNode>
  private let members: UnsafeMutableBufferPointer<JobMember>
  public let root: JobKey

  public init?(
    jobs: UnsafeMutableBufferPointer<JobNode>, members: UnsafeMutableBufferPointer<JobMember>,
    root: borrowing ObjectHeader, limits: JobLimits
  ) {
    guard root.kind == TarwinKind.job, root.ownerJob == 0, limits.valid, !jobs.isEmpty
    else { return nil }
    for i in jobs.indices where jobs[i].id != 0 { return nil }
    for i in members.indices where members[i].id != 0 { return nil }
    self.jobs = jobs
    self.members = members
    self.root = JobKey(slot: 0, generation: 1, id: root.koid)
    jobs[0] = JobNode()
    jobs[0].generation = 1
    jobs[0].id = root.koid
    jobs[0].limits = limits
  }

  private func valid(_ k: JobKey) -> Bool {
    jobs.indices.contains(k.slot) && jobs[k.slot].id == k.id
      && jobs[k.slot].generation == k.generation
  }
  private func valid(_ p: ProcessKey) -> Bool {
    members.indices.contains(p.slot) && members[p.slot].id == p.id
      && members[p.slot].generation == p.generation
  }
  private func walk(_ slot: Int, _ visit: (Int) -> Bool) -> Bool {
    var i: Int? = slot
    while let j = i {
      if !visit(j) { return false }
      i = jobs[j].parent
    }
    return true
  }
  public func policy(_ job: JobKey) -> JobLimits? {
    guard valid(job) else { return nil }
    var limits = jobs[job.slot].limits!
    _ = walk(job.slot) {
      limits = limits.bounded(by: jobs[$0].limits!)
      return true
    }
    return limits
  }
  public func usage(_ job: JobKey) -> JobUsage? { valid(job) ? jobs[job.slot].usage : nil }

  private func available(_ count: Int, _ id: UInt64, _ occupant: (Int) -> (UInt64, UInt64)) -> Int?
  {
    var free: Int?
    for i in 0..<count {
      let (current, generation) = occupant(i)
      if current == id { return nil }
      if current == 0 && generation != .max && free == nil { free = i }
    }
    return free
  }

  public func create(
    _ header: borrowing ObjectHeader, under parent: JobKey, policy limits: JobLimits
  ) -> JobKey? {
    let id = header.koid
    guard header.kind == TarwinKind.job, header.ownerJob == parent.id, let ceiling = policy(parent),
      limits.valid, limits == limits.bounded(by: ceiling), walk(parent.slot, { !jobs[$0].killed }),
      let i = available(jobs.count, id, { (jobs[$0].id, jobs[$0].generation) })
    else { return nil }
    jobs[i].generation += 1
    jobs[i].id = id
    jobs[i].parent = parent.slot
    jobs[i].limits = limits
    return JobKey(slot: i, generation: jobs[i].generation, id: id)
  }
  public func tighten(_ job: JobKey, to limits: JobLimits) -> Bool {
    guard let current = policy(job), limits.valid, limits == limits.bounded(by: current) else {
      return false
    }
    jobs[job.slot].limits = limits
    return true
  }
  public func attach(_ header: borrowing ObjectHeader, to job: JobKey) -> ProcessKey? {
    let id = header.koid
    guard valid(job), header.kind == TarwinKind.process, header.ownerJob == job.id,
      let i = available(members.count, id, { (members[$0].id, members[$0].generation) }),
      walk(
        job.slot,
        {
          !jobs[$0].killed && jobs[$0].limits!.denials & 1 == 0
            && jobs[$0].usage.processes < jobs[$0].limits!.processes
        })
    else { return nil }
    members[i].generation += 1
    members[i].id = id
    members[i].job = job.slot
    members[i].footprint = 0
    _ = walk(job.slot) {
      jobs[$0].usage.processes += 1
      return true
    }
    return ProcessKey(slot: i, generation: members[i].generation, id: id)
  }
  public func resizeFootprint(_ process: ProcessKey, to amount: UInt64) -> Bool {
    guard valid(process) else { return false }
    let old = members[process.slot].footprint
    let job = members[process.slot].job
    if amount > old {
      let delta = amount - old
      guard
        walk(
          job,
          { i in
            let used = jobs[i].usage.footprint
            let limit = jobs[i].limits!.footprint
            return !jobs[i].killed && used <= limit && delta <= limit - used
          })
      else { return false }
      _ = walk(job) {
        jobs[$0].usage.footprint += delta
        return true
      }
    } else {
      _ = walk(job) {
        jobs[$0].usage.footprint -= old - amount
        return true
      }
    }
    members[process.slot].footprint = amount
    return true
  }
  public func detach(_ process: ProcessKey) -> Bool {
    guard valid(process) else { return false }
    let m = members[process.slot]
    _ = walk(m.job) {
      jobs[$0].usage.footprint -= m.footprint
      jobs[$0].usage.processes -= 1
      return true
    }
    members[process.slot].id = 0
    return true
  }
  public func remove(_ job: JobKey) -> Bool {
    guard valid(job), job != root, jobs[job.slot].usage.processes == 0
    else { return false }
    for i in jobs.indices where jobs[i].id != 0 && jobs[i].parent == job.slot { return false }
    let generation = jobs[job.slot].generation
    jobs[job.slot] = JobNode()
    jobs[job.slot].generation = generation
    return true
  }
  public func setFrozen(_ frozen: Bool, job: JobKey) -> Bool {
    guard valid(job), walk(job.slot, { !jobs[$0].killed }) else { return false }
    jobs[job.slot].frozen = frozen
    return true
  }
  public func kill(_ job: JobKey) -> Bool {
    guard valid(job) else { return false }
    jobs[job.slot].killed = true
    return true
  }
  /// Notify after the last *handle* closes, not after the last kernel reference.
  public func lastHandleClosed(_ job: JobKey) {
    if policy(job)?.killOnClose == true { _ = kill(job) }
  }
  /// Scheduler rechecks at the safe point before returning to user mode.
  public func returnGate(_ process: ProcessKey) -> ReturnGate {
    guard valid(process) else { return .terminate }
    var frozen = false
    let alive = walk(members[process.slot].job) {
      frozen = frozen || jobs[$0].frozen
      return !jobs[$0].killed
    }
    return !alive ? .terminate : (frozen ? .frozen : .run)
  }
  /// Identify the threads' processes to kick after a subtree policy or state
  /// change. The visitor must not sleep, reenter the tree or release objects.
  public func visitMembers(of job: JobKey, _ visit: (ProcessKey) -> Void) {
    guard valid(job) else { return }
    for i in members.indices where members[i].id != 0 {
      if !walk(members[i].job, { $0 != job.slot }) {
        visit(ProcessKey(slot: i, generation: members[i].generation, id: members[i].id))
      }
    }
  }
}
