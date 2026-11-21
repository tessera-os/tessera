import TarwinIPC
import TarwinIoCompletion

/// One latched vector and one outstanding notification. Serialize binding,
/// IRQ entry, rearm and teardown. Hardware starts masked and each successful
/// bind/rearm reserves the next terminal packet before enabling the vector.
public struct PortInterrupt: ~Copyable {
  public private(set) var line: DriverInterrupt
  private let object: UInt64, vector: UInt32
  private var pending: IoReservation?
  private(set) var revoking = false
  public init(object: UInt64, epoch: UInt64, vector: UInt32) {
    line = DriverInterrupt(slotEpoch: epoch, state: .armed)
    self.object = object
    self.vector = vector
  }

  public mutating func arm<P: IoPorts & ~Copyable>(
    epoch: UInt64, port: UInt64, key: UInt64, ports: inout P,
    unmask: () -> Void
  ) -> Bool {
    guard !revoking, epoch != 0, epoch == line.slotEpoch, pending == nil,
      line.state == .armed || line.state == .delivered,
      let r = IoReservation(port: port, object: object, key: key, kind: 11, ports: &ports)
    else { return false }
    pending = consume r
    if line.state == .delivered { return line.complete(epoch, unmask) }
    unmask()
    return true
  }

  public mutating func interrupt<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, acknowledgeAndMask: () -> Void
  ) -> Bool {
    if revoking {
      acknowledgeAndMask()
      return false
    }
    guard let r = pending.take() else { return false }
    var published = false
    let v = vector
    let posted = line.deliver(acknowledgeAndMask) { true }
    r.finish(at: now, ports: &ports) {
      var packet = PortPacket()
      packet.result0 = UInt64(v)
      published = true
      return packet
    }
    if !posted || !published {
      line.revoke({})
      return false
    }
    return true
  }

  /// A cancellation worker matches this retained port AND its private
  /// operation, not a key or index which might be reused on another port.
  public func matches(port: UInt64, operation: PortOperation) -> Bool {
    pending?.matches(port: port, operation: operation) == true
  }
  public mutating func revoke<P: IoPorts & ~Copyable>(
    at now: UInt64, ports: inout P, maskAndDrain: () -> Bool
  ) -> Bool {
    revoking = true
    guard maskAndDrain() else { return false }
    line.revoke({})
    if let r = pending.take() {
      r.finish(at: now, ports: &ports) {
        var packet = PortPacket()
        packet.error = 70
        packet.subsystem = 5
        return packet
      }
    }
    return true
  }
}
