import TarwinBlockWire
import TarwinIPC
import TarwinIoCompletion

public struct BlockPortSlot: ~Copyable {
  fileprivate var id: UInt64 = 0, bytes: UInt64 = 0
  fileprivate var reservation: IoReservation?
  fileprivate var terminal: BlockStatus?, cancelling = false
  public init() {}
}

/// One serialized scheduler per device, shared by clients of distinct ports.
/// The caller owns the initialized binding slab until removal and the last
/// release. No pointer to a caller's buffer or port crosses the driver ABI.
public struct PortBlockQueue: ~Copyable {
  private var requests: BlockQueue
  private let slots: UnsafeMutableBufferPointer<BlockPortSlot>, blockBytes: UInt32
  private var stopped = false
  public var epoch: UInt64 { requests.epoch }
  public init?(
    capacity: UInt64, blockBytes: UInt32, queueCount: UInt32, depth: UInt32,
    slots: UnsafeMutableBufferPointer<BlockPortSlot>
  ) {
    guard capacity > 0, blockBytes >= 512, blockBytes.nonzeroBitCount == 1,
      queueCount > 0, depth > 0, !slots.isEmpty, slots.indices.allSatisfy({ slots[$0].id == 0 })
    else { return nil }
    self.slots = slots
    self.blockBytes = blockBytes
    requests = BlockQueue(
      capacity: capacity, queueCount: queueCount, pendingLimit: slots.count, depth: depth)
  }
  public mutating func submit<P: IoPorts & ~Copyable>(
    _ c: BlockCommand, object: UInt64, key: UInt64,
    port: UInt64, ports: inout P
  ) -> UInt64 {
    guard requests.accepts(c), let i = slots.indices.first(where: { slots[$0].id == 0 }) else {
      return 0
    }
    let data = c.op == .read || c.op == .write || c.op == .fua || c.op == .atomic
    let (n, overflow) = (data ? c.blocks : 0).multipliedReportingOverflow(by: UInt64(blockBytes))
    guard !overflow,
      let reservation = IoReservation(port: port, object: object, key: key, kind: 3, ports: &ports)
    else { return 0 }
    let id = requests.enqueueAccepted(c)
    slots[i].reservation = consume reservation
    slots[i].id = id
    slots[i].bytes = n
    return id
  }
  public mutating func publish(
    queue: UInt32, payload: (UInt64, UInt64) -> BlockPayload?, ring: inout RingEndpoint
  ) -> BlockPublish {
    guard !stopped else { return .idle }
    return requests.publish(queue: queue, payload: payload, ring: &ring)
  }
  /// Snapshot the driver's reply once. Never drop a validated completion if
  /// invalidating mappings or releasing buffer pins later has to retry.
  public mutating func receive(queue: UInt32, record: borrowing RingRecord) -> UInt64? {
    guard let r = BlockCompletion(record: record), r.epoch == epoch, r.queue == queue,
      let i = slots.indices.first(where: { slots[$0].id == r.id }), slots[i].terminal == nil,
      let t = requests.lookup(r.id), t.state == .issued, t.command.queue == queue
    else { return nil }
    slots[i].terminal = r.status
    return r.id
  }

  /// A cancellation worker (not the port lock callback) identifies the
  /// private reservation. Issued I/O must still complete or be drained.
  public mutating func cancel(port: UInt64, operation: PortOperation) -> UInt64? {
    guard
      let i = slots.indices.first(where: {
        slots[$0].reservation?.matches(port: port, operation: operation) == true
      })
    else { return nil }
    let id = slots[i].id
    slots[i].cancelling = true
    if requests.lookup(id)?.state == .pending {
      requests.forget(id)
      if slots[i].terminal == nil { slots[i].terminal = .ok }
    }
    return id
  }

  /// retireBuffers synchronously removes driver DMA access and releases
  /// the backend's last buffer reference. False quarantines pins and credit.
  public mutating func release<P: IoPorts & ~Copyable>(
    id: UInt64, at now: UInt64, ports: inout P, retireBuffers: (UInt64) -> Bool
  ) -> Bool {
    guard id != 0, let i = slots.indices.first(where: { slots[$0].id == id }),
      let status = slots[i].terminal,
      retireBuffers(id), let reservation = slots[i].reservation.take()
    else { return false }
    let bytes = slots[i].bytes
    requests.forget(id)
    slots[i] = BlockPortSlot()
    reservation.finish(at: now, ports: &ports) {
      var packet = PortPacket()
      switch status {
      case .ok: packet.result0 = bytes
      case .media:
        packet.error = 90
        packet.subsystem = 5
      case .unsupported:
        packet.error = 10
        packet.subsystem = 5
      case .removed:
        packet.error = 70
        packet.subsystem = 5
      }
      return packet
    }
    return true
  }

  public mutating func stop() { stopped = true }

  /// Hold new publications from stop through drain. Only outstanding live
  /// work is replayed; old-epoch rings and terminal/cancelled work are not.
  public mutating func recover(removed: Bool, drainOldBackend: () -> Bool) -> Bool {
    guard stopped, !requests.offline, drainOldBackend() else { return false }
    for i in slots.indices where slots[i].id != 0 {
      if slots[i].terminal == nil && (removed || slots[i].cancelling) {
        slots[i].terminal = removed ? .removed : .ok
      }
      if slots[i].terminal != nil { requests.forget(slots[i].id) }
    }
    if removed {
      requests.removeDevice { _ in }
      return true
    }
    guard requests.restart() else { return false }
    stopped = false
    return true
  }
}
