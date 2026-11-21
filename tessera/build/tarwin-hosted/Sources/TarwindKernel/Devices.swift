import TarwinArchHosted

extension Tarwind {
  /// H6 providers expose in-process TWHD driver inboxes, not PCI/IOMMU slots.
  public func openHostDevice(process: TarwindProcessID, kind: String, slot: UInt32) throws -> HostPort {
    let provider = try state.lock.withLock {
      guard !state.stopped, state.processes[process] != nil else { throw TarwindError.invalidProcess }
      guard let provider = state.devices.lookup(kind: kind) else { throw TarwindError.unavailable }
      return provider
    }
    let port = try provider.open(slot: slot)
    try state.lock.withLock {
      guard !state.stopped, state.processes[process] != nil else { throw TarwindError.invalidProcess }
    }
    return port
  }
}
