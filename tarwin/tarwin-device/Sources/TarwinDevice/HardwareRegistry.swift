/// Physical locations and resources are supplied by trusted platform enumeration,
/// never by a driver or its match dictionary. A location is not a capability.
public enum DeviceLocation: Equatable {
  case pci(segment: UInt16, requester: UInt16)
  case firmware(UInt64)
}
public struct StableDeviceID: Equatable {
  public let high: UInt64, low: UInt64
  /// The platform derives this from the salted path and optional serial number.
  public init(high: UInt64, low: UInt64) {
    self.high = high
    self.low = low
  }
}
public struct HardwareDevice: Equatable {
  public let location: DeviceLocation, parent: DeviceLocation?, stable: StableDeviceID
  public let identity: UInt64, deviceClass: UInt32, group: UInt64?, mmio: [MmioAperture]
  public let wiredInterrupts: UInt16, powerStates: UInt8, wakeCapable: Bool
  public init(
    location: DeviceLocation, parent: DeviceLocation?, stable: StableDeviceID, identity: UInt64,
    deviceClass: UInt32,
    group: UInt64?, mmio: [MmioAperture], wiredInterrupts: UInt16, powerStates: UInt8,
    wakeCapable: Bool
  ) {
    self.location = location
    self.parent = parent
    self.stable = stable
    self.identity = identity
    self.deviceClass = deviceClass
    self.group = group
    self.mmio = mmio
    self.wiredInterrupts = wiredInterrupts
    self.powerStates = powerStates
    self.wakeCapable = wakeCapable
  }
}
public struct RegistryNode: Equatable {
  public let id: UInt64, parentID: UInt64, device: HardwareDevice
}
public enum Unplug: Equatable { case orderly, surprise }
public enum RegistryEvent: Equatable {
  case removed(UInt64, Unplug)
  case added(RegistryNode)
}
public enum RegistryDelta: Equatable {
  case denied, transitioning, unchanged
  case snapshot(UInt64, [RegistryNode])
  case changes(UInt64, [RegistryEvent])
}
public struct GroupLease: Equatable {
  public let node: UInt64, group: UInt64, process: UInt64, epoch: UInt64
}
public protocol GroupTeardown: ~Copyable {
  mutating func maskInterrupts(group: UInt64) -> Bool
  mutating func revokeMaps(group: UInt64) -> Bool
  mutating func retireDma(group: UInt64) -> Bool
  mutating func reset(group: UInt64) -> Bool
}
private struct RegistryPlan {
  let next: [RegistryNode], events: [RegistryEvent], groups: [UInt64], last: UInt64
  var cursor = 0
}
/// Cold path under a single registry lock. No observer, slot operation or
/// assignment may race reconciliation. Stop new hardware DMA on a hotplug
/// notification before taking the snapshot, including every requester alias.
public struct HardwareRegistry: ~Copyable {
  private let limit: Int
  private var nodes: [RegistryNode] = [], slots: [DeviceSlotState] = [],
    events: [RegistryEvent] = []
  private var pending: RegistryPlan?
  private var frozen = false, superseded = false
  private var last: UInt64 = 0
  public private(set) var revision: UInt64 = 0
  public init?(limit: Int) {
    guard (1...4096).contains(limit) else { return nil }
    self.limit = limit
  }
  /// after == nil requests a snapshot. A lapped consumer resnapshots instead
  /// of silently missing removals. deviceRoot is a kernel-resolved resource.
  public func changes(deviceRoot: Bool, after: UInt64?) -> RegistryDelta {
    guard deviceRoot else { return .denied }
    guard !frozen else { return .transitioning }
    if after == revision { return .unchanged }
    if revision > 0, after == revision - 1 { return .changes(revision, events) }
    return .snapshot(revision, nodes)
  }
  /// Freeze admission on the hardware notification, before enumeration.
  /// If a drain is already in flight, its commit must not thaw admission.
  public mutating func freeze() {
    frozen = true
    if pending != nil { superseded = true }
  }
  /// Input is a complete, parent-first platform snapshot. To represent a
  /// remove/reinsert at the same address with identical hardware, supply its
  /// known disappeared location in replaced. Changes cover the whole group.
  public mutating func stage(
    _ snapshot: [HardwareDevice], replaced: [DeviceLocation] = [], reason: Unplug
  ) -> Bool {
    freeze()
    guard pending == nil, revision < .max, snapshot.count <= limit, replaced.count <= limit else {
      return false
    }
    var ranges: [DeviceRange] = []
    for (i, d) in snapshot.enumerated() {
      guard d.stable.high != 0 || d.stable.low != 0, d.group != 0, d.mmio.count <= 16,
        d.powerStates & ~31 == 0,
        !snapshot[..<i].contains(where: { $0.stable == d.stable || $0.location == d.location }),
        d.parent == nil || snapshot[..<i].contains(where: { $0.location == d.parent })
      else { return false }
      for a in d.mmio {
        guard a.range.valid() else { return false }
        ranges.append(a.range)
      }
    }
    ranges.sort { $0.base < $1.base }
    for i in ranges.indices.dropFirst() where ranges[i - 1].overlaps(ranges[i]) { return false }

    var revoked = [Bool](repeating: false, count: nodes.count)
    var work: [Int] = []
    func mark(_ i: Int) {
      if !revoked[i] {
        revoked[i] = true
        work.append(i)
      }
    }
    for (i, node) in nodes.enumerated() {
      if replaced.contains(node.device.location) || !snapshot.contains(node.device) { mark(i) }
    }
    // A newly attached group member changes the isolation boundary even if
    // every old member's individual firmware resources are unchanged.
    for d in snapshot where !nodes.contains(where: { $0.device == d }) {
      if let g = d.group { for i in nodes.indices where nodes[i].device.group == g { mark(i) } }
    }
    var cursor = 0
    while cursor < work.count {
      let n = nodes[work[cursor]]
      cursor += 1
      for i in nodes.indices
      where !revoked[i]
        && (nodes[i].parentID == n.id
          || (n.device.group != nil && nodes[i].device.group == n.device.group))
      { mark(i) }
    }
    var affected: [UInt64] = []
    var changes: [RegistryEvent] = []
    var next: [RegistryNode] = []
    var serial = last
    for i in nodes.indices.reversed() where revoked[i] {
      let n = nodes[i]
      changes.append(.removed(n.id, reason))
      if let g = n.device.group, !affected.contains(g) { affected.append(g) }
    }
    for d in snapshot {
      if let i = nodes.firstIndex(where: { $0.device == d }), !revoked[i] {
        next.append(nodes[i])
        continue
      }
      guard serial < .max else { return false }
      serial += 1
      let parent = d.parent.flatMap { loc in next.first(where: { $0.device.location == loc })?.id }
      let n = RegistryNode(id: serial, parentID: parent ?? 0, device: d)
      next.append(n)
      changes.append(.added(n))
    }
    pending = RegistryPlan(next: next, events: changes, groups: affected, last: serial)
    return true
  }
  /// A failed drain keeps the transaction and all old mappings quarantined.
  /// Do not unmask/enable new requesters until the new slot is assigned.
  public mutating func commit<P: GroupTeardown & ~Copyable>(_ provider: inout P) -> Bool {
    guard var plan = pending else { return false }
    while plan.cursor < plan.groups.count {
      let g = plan.groups[plan.cursor]
      if let i = slots.firstIndex(where: { $0.group == g }) {
        guard
          slots[i].revoke(
            !plan.next.contains(where: { $0.device.group == g }),
            { provider.maskInterrupts(group: g) }, { provider.revokeMaps(group: g) },
            { provider.retireDma(group: g) }, { provider.reset(group: g) })
        else {
          pending = plan
          return false
        }
        slots.remove(at: i)
      }
      plan.cursor += 1
    }
    pending = nil
    frozen = superseded
    superseded = false
    if !plan.events.isEmpty {
      last = plan.last
      nodes = plan.next
      events = plan.events
      revision += 1
    }
    return true
  }
  public mutating func assign(
    deviceRoot: Bool, node: UInt64, process: UInt64, isolate: (UInt64, UInt64) -> Bool
  ) -> GroupLease? {
    guard deviceRoot, !frozen, let g = nodes.first(where: { $0.id == node })?.device.group
    else { return nil }
    let i: Int
    if let index = slots.firstIndex(where: { $0.group == g }) {
      i = index
    } else {
      i = slots.count
      slots.append(DeviceSlotState(group: g))
    }
    guard slots[i].assign(deviceRoot, process, isolate) else { return nil }
    return GroupLease(node: node, group: g, process: process, epoch: slots[i].epoch)
  }
  public func permits(_ lease: GroupLease, process: UInt64, node: UInt64) -> Bool {
    !frozen && process == lease.process
      && nodes.contains(where: { $0.id == lease.node && $0.device.group == lease.group })
      && nodes.contains(where: { $0.id == node && $0.device.group == lease.group })
      && slots.contains(where: { $0.group == lease.group && $0.owns(process, lease.epoch) })
  }
  public mutating func revoke<P: GroupTeardown & ~Copyable>(
    _ lease: GroupLease, deviceRoot: Bool, provider: inout P
  ) -> Bool {
    guard deviceRoot, pending == nil,
      nodes.contains(where: { $0.id == lease.node && $0.device.group == lease.group }),
      let i = slots.firstIndex(where: {
        $0.group == lease.group && $0.epoch == lease.epoch && $0.owner == lease.process
      })
    else { return false }
    let g = lease.group
    return slots[i].revoke(
      false, { provider.maskInterrupts(group: g) }, { provider.revokeMaps(group: g) },
      { provider.retireDma(group: g) }, { provider.reset(group: g) })
  }
}
