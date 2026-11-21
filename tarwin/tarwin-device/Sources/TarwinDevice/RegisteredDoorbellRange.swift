import TarwinObject

public struct RegisteredDoorbellRange: ~Copyable {
  private let lease: GroupLease, node: UInt64
  private var mappings: DoorbellMappings
  init(lease: GroupLease, node: UInt64, mappings: consuming DoorbellMappings) {
    self.lease = lease
    self.node = node
    self.mappings = consume mappings
  }

  public mutating func grant(
    rangeName: UInt64, processName: UInt64, offset: UInt64,
    registry: borrowing HardwareRegistry, callerProcess: UInt64, caller: HandleReadView,
    installWriteOnlyUcNx: (DoorbellMapping, UnsafePointer<ObjectHeader>) -> DoorbellInstall,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> DoorbellReply {
    guard callerProcess == lease.process else { return .denied }
    guard let slot = registry.activeSlot(lease, process: callerProcess, node: node) else {
      return .unavailable
    }
    return mappings.grant(
      rangeName: rangeName, processName: processName, offset: offset,
      slot: slot, callerProcess: callerProcess, caller: caller,
      installWriteOnlyUcNx: installWriteOnlyUcNx,
      retire: retire)
  }

  /// Called for every registered range from GroupTeardown.revokeMaps. Does not
  /// require an active lease: unplug has already frozen registry admission.
  public mutating func revoke(
    group: UInt64,
    unmapAndSync: (DoorbellMapping, UnsafePointer<ObjectHeader>) -> Bool,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    mappings.revoke(group: group, epoch: lease.epoch, unmapAndSync: unmapAndSync, retire: retire)
  }
}
