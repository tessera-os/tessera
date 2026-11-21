public struct CpuOffer {
  public let online: Bool
  public let features: UInt64
  public let capacity: UInt32
  public let energy: UInt32
  public let load: UInt32
  public let efficiency: Bool
  public let idle: Bool
  public let thermalHeadroom: Bool
  public let runningSiblingJob: UInt64
  public let isolatedSiblings: Bool

  public init(
    online: Bool, features: UInt64, capacity: UInt32, energy: UInt32, load: UInt32,
    efficiency: Bool, idle: Bool, thermalHeadroom: Bool, runningSiblingJob: UInt64,
    isolatedSiblings: Bool
  ) {
    self.online = online
    self.features = features
    self.capacity = capacity
    self.energy = energy
    self.load = load
    self.efficiency = efficiency
    self.idle = idle
    self.thermalHeadroom = thermalHeadroom
    self.runningSiblingJob = runningSiblingJob
    self.isolatedSiblings = isolatedSiblings
  }
}

// CPPC/DT model supplies capacity and energy at the candidate operating
// point. On vulnerable SMT cores a non-idle sibling must share the job.
public func cpuEligible(
  _ cpu: CpuOffer, _ required: UInt64, _ job: UInt64, _ qos: UInt8,
  _ demand: UInt32, _ haveEfficiency: Bool
) -> Bool {
  if !cpu.online || (cpu.features & required) != required { return false }
  if cpu.isolatedSiblings && cpu.runningSiblingJob != 0 && cpu.runningSiblingJob != job {
    return false
  }
  if haveEfficiency && !cpu.efficiency {
    if qos == SchedClass.background { return false }
    if qos == SchedClass.utility && (!cpu.idle || !cpu.thermalHeadroom) { return false }
  }
  return demand <= cpu.capacity
}

// Rank eligible operating points after filtering. Equal points retain the
// queue's stable CPU order.
public func cpuBefore(_ candidate: CpuOffer, _ other: CpuOffer, _ qos: UInt8) -> Bool {
  if qos == SchedClass.utility && candidate.efficiency != other.efficiency {
    return candidate.efficiency
  }
  if candidate.energy != other.energy { return candidate.energy < other.energy }
  return candidate.load < other.load
}

/// One CPU at one supported frequency. The platform supplies actual
/// operating points and the current thermal ceiling for the CPU's cluster.
public struct OperatingPoint {
  public let offer: CpuOffer
  public let hz: UInt64
  public let ceilingHz: UInt64
  public init(offer: CpuOffer, hz: UInt64, ceilingHz: UInt64) {
    self.offer = offer
    self.hz = hz
    self.ceilingHz = ceilingHz
  }
}

/// Choose the least-energy eligible operating point that meets demand
/// (including any active work interval). When none can, choose the fastest
/// permitted point. Never trade CPU features or isolation for a deadline.
public func selectOperatingPoint(
  _ points: UnsafeBufferPointer<OperatingPoint>,
  required: UInt64, job: UInt64, qos: UInt8, demand: UInt32, haveEfficiency: Bool
) -> Int? {
  guard job != 0, (SchedClass.background...SchedClass.deadline).contains(qos) else { return nil }
  var best: Int?
  for i in points.indices {
    let p = points[i]
    let cpu = p.offer
    guard p.hz != 0, p.hz <= p.ceilingHz, cpu.capacity != 0,
      cpuEligible(cpu, required, job, qos, 0, haveEfficiency)
    else { continue }
    if let b = best {
      let other = points[b].offer
      let meets = cpu.capacity >= demand
      let otherMeets = other.capacity >= demand
      if meets != otherMeets {
        if meets { best = i }
        continue
      }
      if !meets && cpu.capacity != other.capacity {
        if cpu.capacity > other.capacity { best = i }
        continue
      }
      if !cpuBefore(cpu, other, qos) { continue }
    }
    best = i
  }
  return best
}
