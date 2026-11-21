import TarwinABI
import TarwinObject
import TarwinSyscall

public protocol DoorbellVmLifetime: ~Copyable {
  mutating func installWriteOnlyUcNx(
    _ mapping: DoorbellMapping, in process: UnsafePointer<ObjectHeader>
  ) -> DoorbellInstall
  mutating func unmapAndSync(_ mapping: DoorbellMapping, in process: UnsafePointer<ObjectHeader>)
    -> Bool
  mutating func retire(_ header: UnsafePointer<ObjectHeader>)
}

public struct DoorbellRangeEntry: ~Copyable {
  fileprivate var binding: RegisteredDoorbellRange?
  fileprivate var header: UnsafePointer<ObjectHeader>?
  fileprivate var group: UInt64 = 0, node: UInt64 = 0, bar: Int = 0
  public init() {}
}

/// Exclusive initialized slab, kept alive until all its groups have drained.
/// Use this same provider for syscall lookup, explicit slot revocation and
/// hardware registry commit. The underlying provider handles other resources.
public struct DoorbellResources<B: GroupTeardown & ~Copyable, V: DoorbellVmLifetime & ~Copyable>:
  GroupTeardown, ~Copyable
{
  public var base: B, vm: V
  private let entries: UnsafeMutableBufferPointer<DoorbellRangeEntry>
  public init?(
    base: consuming B, vm: consuming V, entries: UnsafeMutableBufferPointer<DoorbellRangeEntry>
  ) {
    for i in entries.indices where entries[i].header != nil { return nil }
    self.base = consume base
    self.vm = consume vm
    self.entries = entries
  }

  /// Hold the registry lock; bind before publishing the range to the driver.
  public mutating func bind(
    _ header: UnsafePointer<ObjectHeader>, registry: borrowing HardwareRegistry,
    lease: GroupLease, node: UInt64, apertureIndex: Int, pageBytes: UInt64,
    designated: UnsafeMutableBufferPointer<DoorbellPage>
  ) -> Bool {
    var free: Int?
    for i in entries.indices {
      if entries[i].header == nil {
        if free == nil { free = i }
      } else if entries[i].header == header
        || (entries[i].node == node && entries[i].bar == apertureIndex)
      {
        return false
      }
    }
    guard let i = free,
      let binding = registry.bindDoorbellRange(
        header, lease: lease, node: node,
        apertureIndex: apertureIndex, pageBytes: pageBytes, designated: designated),
      header.pointee.retainIfLive()
    else { return false }
    entries[i].group = lease.group
    entries[i].node = node
    entries[i].bar = apertureIndex
    entries[i].header = header
    entries[i].binding = consume binding
    return true
  }

  public mutating func issue(
    _ query: DoorbellGrantQuery, to process: inout ProcessExecution,
    tree: borrowing JobTree, registry: borrowing HardwareRegistry
  ) -> CallResult {
    let owner = process.member.id
    return process.withHandles(tree: tree) { table in
      let reader = table.reader
      func live(_ h: UnsafePointer<ObjectHeader>) {
        preconditionFailure("lost live process handle")
      }
      switch reader.pinWithinEpoch(query.range, kind: TarwinKind.mmioRange, need: 528) {
      case .invalidHandle: return doorbellError(2)
      case .wrongType: return doorbellError(3)
      case .accessDenied: return doorbellError(4)
      case .found(let pin):
        let header = pin.header
        // Both handles stay live under the process writer lock.
        pin.drop(retire: live)
        for i in entries.indices where entries[i].header == header {
          switch entries[i].binding!.grant(
            rangeName: query.range, processName: query.target, offset: query.offset,
            registry: registry, callerProcess: owner, caller: reader,
            installWriteOnlyUcNx: { vm.installWriteOnlyUcNx($0, in: $1) }, retire: live)
          {
          case .mapped: return CallResult()
          case .invalidHandle: return doorbellError(2)
          case .wrongType: return doorbellError(3)
          case .denied, .notDesignated: return doorbellError(4)
          case .busy: return doorbellError(22)
          case .unavailable: return doorbellError(70)
          case .mappingFailed: return doorbellError(23)
          }
        }
        return doorbellError(70)
      }
    } ?? doorbellError(23)
  }

  public mutating func maskInterrupts(group: UInt64) -> Bool { base.maskInterrupts(group: group) }
  public mutating func revokeMaps(group: UInt64) -> Bool {
    var done = true
    for i in entries.indices where entries[i].group == group {
      guard let header = entries[i].header else { continue }
      if entries[i].binding!.revoke(
        group: group, unmapAndSync: { vm.unmapAndSync($0, in: $1) },
        retire: { vm.retire($0) })
      {
        entries[i] = DoorbellRangeEntry()
        if header.pointee.release() == .destroy { vm.retire(header) }
      } else {
        done = false
      }
    }
    guard done else { return false }
    return base.revokeMaps(group: group)
  }
  public mutating func retireDma(group: UInt64) -> Bool { base.retireDma(group: group) }
  public mutating func reset(group: UInt64) -> Bool { base.reset(group: group) }
}
