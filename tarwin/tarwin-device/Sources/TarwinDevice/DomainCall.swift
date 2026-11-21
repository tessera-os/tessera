import TarwinABI
import TarwinObject
import TarwinSyscall

/// A registry record, created after isolation succeeds. The registry owns live
/// references to both headers until the last locked lookup has finished.
public struct SlotDomainBinding {
  let slot: UnsafePointer<ObjectHeader>, domain: UnsafePointer<ObjectHeader>
  let lease: GroupLease
  public init?(
    slot: UnsafePointer<ObjectHeader>, domain: UnsafePointer<ObjectHeader>,
    lease: GroupLease, backing: borrowing SlotDomain
  ) {
    guard slot.pointee.kind == TarwinKind.deviceSlot, domain.pointee.kind == TarwinKind.iommuDomain,
      domain.pointee.koid == backing.koid, domain.pointee.maximumRights & 512 != 0,
      lease.group == backing.group, lease.epoch == backing.epoch
    else { return nil }
    self.slot = slot
    self.domain = domain
    self.lease = lease
  }
}

public struct SlotDomainQuery {
  fileprivate let name: UInt64
  /// Under the hotplug and current process table writer locks. Do not create
  /// a new domain or bind hardware here: look up the retained slot's record.
  public func issue(
    to process: inout ProcessExecution, tree: borrowing JobTree,
    registry: borrowing HardwareRegistry,
    lookup: (UnsafePointer<ObjectHeader>) -> SlotDomainBinding?
  ) -> CallResult {
    let owner = process.member.id
    return process.withHandles(tree: tree) {
      issue(process: owner, table: &$0, registry: registry, lookup: lookup)
    } ?? CallResult(status: syscallStatus(23, 5))
  }
  private func issue(
    process: UInt64, table: inout HandleTable, registry: borrowing HardwareRegistry,
    lookup: (UnsafePointer<ObjectHeader>) -> SlotDomainBinding?
  ) -> CallResult {
    func error(_ code: UInt32) -> CallResult { CallResult(status: syscallStatus(code, 5)) }
    let pin = table.reader.pinWithinEpoch(name, kind: TarwinKind.deviceSlot, need: 512)
    switch consume pin {
    case .invalidHandle: return error(2)
    case .wrongType: return error(3)
    case .accessDenied: return error(4)
    case .found(let slot):
      let header = slot.header
      let record = lookup(header)
      // Holding the writer lock keeps the original slot handle live.
      slot.drop { _ in preconditionFailure("live slot lost its table reference") }
      guard let record, record.slot == header else { return error(70) }
      guard process == record.lease.process else { return error(4) }
      guard registry.permits(record.lease, process: process, node: record.lease.node)
      else { return error(70) }
      switch table.install(record.domain, rights: 512) {
      case .installed(let name): return CallResult(first: name)
      case .limit: return error(33)
      case .accessDenied: return error(4)
      case .invalidHandle: return error(70)
      }
    }
  }
}

public protocol SlotDomainCallContext {
  /// Select the scheduler's current process and serialize with job policy,
  /// process exit, handle mutations and device registry reconciliation.
  mutating func withLockedCaller(_ query: SlotDomainQuery) -> CallResult
}

public struct SlotDomainCall<C: SlotDomainCallContext>: CallProvider {
  public var context: C
  public init(_ context: C) { self.context = context }
  public func argumentCount(for number: UInt64) -> UInt32? {
    number == TarwinCall.deviceSlotIommuDomain ? 1 : nil
  }
  public mutating func copyUserWords(
    from address: UInt64, into destination: UnsafeMutableBufferPointer<UInt64>
  ) -> Bool { false }
  public mutating func invoke(number: UInt64, words: UnsafeBufferPointer<UInt64>) -> CallResult {
    guard number == TarwinCall.deviceSlotIommuDomain else {
      return CallResult(status: syscallStatus(10, 5))
    }
    guard words.count == 1 else { return CallResult(status: syscallStatus(1, 5)) }
    return context.withLockedCaller(SlotDomainQuery(name: words[0]))
  }
}
