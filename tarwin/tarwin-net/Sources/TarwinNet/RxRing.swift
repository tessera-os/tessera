import TarwinIPC
import TarwinNetWire

public struct RxSlot {
  fileprivate var id: UInt64 = 0, pin: UInt64 = 0, bytes: UInt32 = 0, received: UInt32 = 0
  public init() {}
}
/// One queue per hardware RX ring. A caller transfers a distinct writable
/// pin only on successful publication; it retains ownership on backpressure.
public struct InterfaceRxQueue: ~Copyable {
  public let queue: UInt32, maximum: UInt32
  public private(set) var epoch: UInt64 = 1, phase: InterfacePhase = .running
  private var last: UInt64 = 0
  private let slots: UnsafeMutableBufferPointer<RxSlot>
  public init?(queue: UInt32, maximum: UInt32, slots: UnsafeMutableBufferPointer<RxSlot>) {
    guard (14...65553).contains(maximum), !slots.isEmpty, slots.allSatisfy({ $0.id == 0 }) else {
      return nil
    }
    self.queue = queue
    self.maximum = maximum
    self.slots = slots
  }
  public mutating func post(pin: UInt64, iova: UInt64, ring: inout RingEndpoint) -> RingStep {
    guard phase == .running, pin != 0, last < .max,
      !slots.contains(where: { $0.pin == pin }),
      let entry = slots.indices.first(where: { slots[$0].id == 0 }),
      let f = NetFrame(
        direction: .receive, queue: queue, id: last + 1, epoch: epoch, iova: iova, bytes: maximum)
    else { return .wait }
    let step = ring.push(f.record())
    if case .transferred = step {
      last += 1
      slots[entry] = RxSlot(id: last, pin: pin, bytes: maximum, received: 0)
    }
    return step
  }
  public mutating func receive(_ r: borrowing RingRecord) -> UInt64? {
    guard phase == .running, let d = NetFrameDone(record: r), d.direction == .receive,
      d.queue == queue, d.epoch == epoch,
      let i = slots.indices.first(where: { slots[$0].id == d.id }), slots[i].received == 0,
      d.bytes <= slots[i].bytes
    else { return nil }
    slots[i].received = d.bytes
    return d.id
  }
  /// sync removes device write access and performs cache maintenance. On
  /// failure nothing is delivered and the buffer stays pinned for retry.
  public mutating func deliver(
    id: UInt64, sync: (UInt64) -> Bool, consume: (UInt64, UInt32) -> Void
  ) -> Bool {
    guard phase == .running, id != 0, let i = slots.indices.first(where: { slots[$0].id == id }),
      slots[i].received > 0, sync(slots[i].pin)
    else { return false }
    let slot = slots[i]
    slots[i] = RxSlot()
    consume(slot.pin, slot.received)
    return true
  }
  public mutating func stop() { if phase == .running { phase = .stopped } }
  public mutating func recover(removed: Bool, drain: () -> Bool, reclaim: (UInt64) -> Void) -> Bool
  {
    guard phase == .stopped, removed || epoch < .max, drain() else { return false }
    for i in slots.indices where slots[i].id != 0 {
      let pin = slots[i].pin
      slots[i] = RxSlot()
      reclaim(pin)
    }
    if removed {
      phase = .removed
    } else {
      epoch += 1
      phase = .running
    }
    return true
  }
}
extension RxSlot {
  fileprivate init(id: UInt64, pin: UInt64, bytes: UInt32, received: UInt32) {
    self.id = id
    self.pin = pin
    self.bytes = bytes
    self.received = received
  }
}
