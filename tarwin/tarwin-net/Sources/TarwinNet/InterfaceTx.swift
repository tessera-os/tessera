import TarwinIPC
import TarwinNetWire

public struct TxPacket {
  public let process: UInt64, flow: UInt64, memory: UInt64, offset: UInt64, bytes: UInt32
  public let notBefore: UInt64, background: Bool
  public init(
    process: UInt64, flow: UInt64, memory: UInt64, offset: UInt64, bytes: UInt32,
    notBefore: UInt64, background: Bool
  ) {
    self.process = process
    self.flow = flow
    self.memory = memory
    self.offset = offset
    self.bytes = bytes
    self.notBefore = notBefore
    self.background = background
  }
}
public struct TxSlot {
  fileprivate var request: TxPacket?, key: UInt64 = 0, pin: UInt64 = 0, finish: UInt64 = 0
  fileprivate var wireQueue: UInt32?
  fileprivate var next: Int = -1, owner: Int = -1, published = false
  public init() {}
}
public struct TxFlow {
  fileprivate var process: UInt64 = 0, id: UInt64 = 0, finish: UInt64 = 0
  fileprivate var head: Int = -1, tail: Int = -1, retained = 0
  public init() {}
}
public enum TxDisposition { case transmitted, inFlightLost, deviceRemoved }
public enum InterfacePhase { case running, stopped, removed }

/// Serialized per interface. Both initialized slabs are exclusive to the
/// queue for its lifetime. Driver replacement preserves packet pins, not
/// device IOVAs, and never publishes into the old ring after stop().
public struct InterfaceTxQueue: ~Copyable {
  private let packets: UnsafeMutableBufferPointer<TxSlot>, flows: UnsafeMutableBufferPointer<TxFlow>
  public private(set) var epoch: UInt64 = 1, phase: InterfacePhase = .running
  private var issued: UInt64 = 0, virtualTime: UInt64 = 0

  public init(
    packets: UnsafeMutableBufferPointer<TxSlot>, flows: UnsafeMutableBufferPointer<TxFlow>
  ) {
    self.packets = packets
    self.flows = flows
  }

  public mutating func enqueue(
    _ p: TxPacket, allowed: (UInt64, UInt64) -> Bool,
    pin: (UInt64, UInt64, UInt64, UInt32) -> UInt64
  ) -> UInt64 {
    guard phase != .removed, p.process != 0, p.flow != 0, p.memory != 0, p.bytes != 0,
      p.offset <= .max - UInt64(p.bytes - 1), issued < .max, allowed(p.process, p.flow),
      let i = packets.indices.first(where: { packets[$0].key == 0 }),
      let f = flows.indices.first(where: {
        flows[$0].process == p.process && flows[$0].id == p.flow
      })
        ?? flows.indices.first(where: { flows[$0].id == 0 })
    else { return 0 }
    let token = pin(p.process, p.memory, p.offset, p.bytes)
    guard token != 0 else { return 0 }
    issued += 1
    flows[f].process = p.process
    flows[f].id = p.flow
    flows[f].finish = flowFinish(flows[f].finish, virtualTime, p.bytes)
    packets[i].request = p
    packets[i].key = issued
    packets[i].pin = token
    packets[i].finish = flows[f].finish
    packets[i].owner = f
    if flows[f].tail >= 0 { packets[flows[f].tail].next = i } else { flows[f].head = i }
    flows[f].tail = i
    flows[f].retained += 1
    return issued
  }

  /// publish maps this pin into the current domain and commits its descriptor
  /// atomically; false means nothing was published (including ring-full).
  public mutating func dispatch(
    now: UInt64, congested: Bool,
    publish: (UInt64, UInt64, UInt64, UInt32) -> Bool
  ) -> Bool {
    dispatch(wireQueue: nil, now: now, congested: congested, publish: publish)
  }
  private mutating func dispatch(
    wireQueue: UInt32?, now: UInt64, congested: Bool,
    publish: (UInt64, UInt64, UInt64, UInt32) -> Bool
  ) -> Bool {
    guard phase == .running else { return false }
    var chosen = -1
    for f in flows {
      let i = f.head
      guard i >= 0, let p = packets[i].request, p.notBefore <= now else { continue }
      if chosen >= 0, let old = packets[chosen].request {
        if congested && old.background != p.background {
          if p.background { continue }
        } else if packets[i].finish > packets[chosen].finish
          || (packets[i].finish == packets[chosen].finish && packets[i].key > packets[chosen].key)
        {
          continue
        }
      }
      chosen = i
    }
    guard chosen >= 0, let p = packets[chosen].request,
      publish(epoch, packets[chosen].key, packets[chosen].pin, p.bytes)
    else { return false }
    let f = packets[chosen].owner
    virtualTime = max(virtualTime, packets[chosen].finish)
    flows[f].head = packets[chosen].next
    if flows[f].head < 0 { flows[f].tail = -1 }
    packets[chosen].wireQueue = wireQueue
    packets[chosen].published = true
    packets[chosen].next = -1
    return true
  }

  /// The mapping for (epoch, key) is stable until completion or old-domain drain,
  /// including retries on ring backpressure. Never expose a pin token on the wire.
  public mutating func publish(
    queue: UInt32, now: UInt64, congested: Bool,
    iova: (UInt64, UInt64, UInt64, UInt32) -> UInt64?, ring: inout RingEndpoint
  ) -> RingStep? {
    var step: RingStep?
    _ = dispatch(wireQueue: queue, now: now, congested: congested) { e, key, pin, n in
      guard let address = iova(e, key, pin, n),
        let f = NetFrame(
          direction: .transmit, queue: queue, id: key, epoch: e, iova: address, bytes: n)
      else { return false }
      let result = ring.push(f.record())
      step = result
      if case .transferred = result { return true }
      return false
    }
    return step
  }
  public mutating func finish(
    queue: UInt32, record: borrowing RingRecord,
    retireMapping: (UInt64) -> Bool, done: (UInt64, UInt64, TxDisposition) -> Void
  ) -> Bool {
    guard phase == .running, let d = NetFrameDone(record: record), d.epoch == epoch,
      d.direction == .transmit, d.queue == queue,
      let i = packets.indices.first(where: { packets[$0].key == d.id && packets[$0].published }),
      packets[i].wireQueue == queue, packets[i].request?.bytes == d.bytes,
      retireMapping(packets[i].pin)
    else { return false }
    finish(i, .transmitted, done)
    return true
  }
  private func finish(
    _ i: Int, _ result: TxDisposition, _ retire: (UInt64, UInt64, TxDisposition) -> Void
  ) {
    let slot = packets[i]
    let f = slot.owner
    packets[i] = TxSlot()
    flows[f].retained -= 1
    if flows[f].retained == 0 { flows[f] = TxFlow() }
    retire(slot.key, slot.pin, result)
  }

  public mutating func complete(
    epoch reported: UInt64, key: UInt64,
    retire: (UInt64, UInt64, TxDisposition) -> Void
  ) -> Bool {
    guard phase == .running, reported == epoch, key != 0,
      let i = packets.indices.first(where: {
        packets[$0].key == key && packets[$0].published && packets[$0].wireQueue == nil
      })
    else { return false }
    finish(i, .transmitted, retire)
    return true
  }
  public mutating func stop() { if phase == .running { phase = .stopped } }

  /// Never replay an already published datagram; TCP recovers in-flight loss
  /// in its own sequence space. Not-yet-published packets survive in FIFO order.
  public mutating func recover(
    removed: Bool, drainOldDomain: () -> Bool,
    retire: (UInt64, UInt64, TxDisposition) -> Void
  ) -> Bool {
    guard phase == .stopped, removed || epoch < .max, drainOldDomain() else { return false }
    for i in packets.indices where packets[i].key != 0 && (removed || packets[i].published) {
      finish(i, removed ? .deviceRemoved : .inFlightLost, retire)
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
