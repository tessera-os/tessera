import TarwinObject

public enum GpuBacking { case system, deviceLocal }

/// Unique kernel payload for the allocation. CPU and GPU views share this
/// record; neither the allocation size nor its owner is supplied by a client.
public struct GpuAllocation: ~Copyable {
  public let id: UInt64, bytes: UInt64, backing: GpuBacking
  fileprivate enum State: Equatable {
    case fresh
    case charged(ProcessKey)
    case retired
  }
  fileprivate var state: State = .fresh
  public init?(id: UInt64, bytes: UInt64, backing: GpuBacking) {
    guard id != 0, bytes != 0 else { return nil }
    self.id = id
    self.bytes = bytes
    self.backing = backing
  }
}

/// Embed one ledger in each process payload. Serialize updates with the
/// job tree and the VM footprint writer. nonGpu is their current synchronized
/// resident-private + compressed-stored + charged-kernel total for this process,
/// excluding GPU-backed pages. Never use a user-provided accounting snapshot.
public struct GpuFootprint: ~Copyable {
  public let member: ProcessKey, limit: UInt64, objectLimit: UInt32
  public private(set) var used: UInt64 = 0, count: UInt32 = 0

  public init(member: ProcessKey, limit: UInt64, objectLimit: UInt32) {
    self.member = member
    self.limit = limit
    self.objectLimit = objectLimit
  }

  /// Called before publishing the memory or mapping. The device manager
  /// has authenticated the driver and slot; hold the driver's handle read epoch.
  public mutating func charge(
    _ allocation: inout GpuAllocation, client: borrowing ProcessExecution, name: UInt64,
    driver: HandleReadView, nonGpu: UInt64, tree: borrowing JobTree,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard allocation.state == .fresh, count < objectLimit, allocation.bytes <= limit - used,
      client.member == member, client.exit == nil, tree.returnGate(member) != .terminate,
      case .found(let grant) = driver.pinWithinEpoch(name, kind: TarwinKind.process, need: 1 << 9)
    else { return false }
    let matches = grant.header == client.header
    grant.drop(retire: retire)
    let next = used + allocation.bytes
    let (total, overflow) = nonGpu.addingReportingOverflow(next)
    guard matches, !overflow, tree.resizeFootprint(member, to: total) else { return false }
    allocation.state = .charged(member)
    used = next
    count += 1
    return true
  }

  /// Closing a handle does not retire memory. The final owner checks that
  /// *all* mappings and DMA have drained outside these locks; isRetired only
  /// observes that terminal state. Drain all charges before detaching the job member.
  public mutating func release(
    _ allocation: inout GpuAllocation, nonGpu: UInt64, tree: borrowing JobTree,
    isRetired: (UInt64) -> Bool
  ) -> Bool {
    guard allocation.state == .charged(member), count != 0, used >= allocation.bytes,
      isRetired(allocation.id)
    else { return false }
    let next = used - allocation.bytes
    let (total, overflow) = nonGpu.addingReportingOverflow(next)
    guard !overflow, tree.resizeFootprint(member, to: total) else { return false }
    allocation.state = .retired
    used = next
    count -= 1
    return true
  }
}
