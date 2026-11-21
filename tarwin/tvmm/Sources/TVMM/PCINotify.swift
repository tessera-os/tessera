// All methods address pinned ranges of a single VM; the composition root
// retains the pin for the operation. load16/store16Release are indivisible
// little-endian accesses with acquire/release ordering on shared guest RAM.
public protocol PinnedQueueMemory {
  func load16Acquire(_ guest: UInt64) -> UInt16
  func store16Release(_ guest: UInt64, _ value: UInt16)
  func read(_ guest: UInt64, count: Int) -> [UInt8]
  func store32(_ guest: UInt64, _ value: UInt32)
  // Full fence between used publication and reading driver event suppression.
  func beforeNotificationCheck()
}

extension QueuePump {
  // Service a kick under this queue's lock. The transfer closure pins the
  // validated payload ranges independently and returns only after completion.
  public mutating func notify(
    _ layout: SplitQueueLayout, in ram: GuestAperture, eventIndex: Bool,
    memory: some PinnedQueueMemory, transfer: ([Segment]) -> UInt64?,
    interrupt: () -> Void
  ) -> PumpResult {
    guard layout.enabled, slots == Int(layout.size), layout.valid(in: ram, eventIndex: eventIndex)
    else { return .broken }
    let previous = nextUsed
    var final = PumpResult.drained
    let n = slots
    for _ in 0..<min(n, 64) {
      let result = serviceOne(
        { UInt64(memory.load16Acquire(layout.driver + 2)) },
        { UInt64(memory.load16Acquire(layout.driver + 4 + $0 * 2)) },
        { head in
          descriptorChain(n, head, ram) {
            memory.read(layout.descriptor + UInt64($0 * 16), count: 16)
          }
        },
        { transfer($0) ?? .max },
        { slot, head, used in
          let entry = layout.device + 4 + slot * 8
          memory.store32(entry, UInt32(head))
          memory.store32(entry + 4, UInt32(used))
        },
        { memory.store16Release(layout.device + 2, UInt16($0)) })
      if result == .broken {
        final = .broken
        break
      }
      if result == .drained { break }
      final = .progress
    }
    if nextUsed != previous {
      memory.beforeNotificationCheck()
      let notify =
        eventIndex
        ? needEvent(
          UInt64(memory.load16Acquire(layout.driver + 4 + UInt64(layout.size) * 2)), nextUsed,
          previous)
        : memory.load16Acquire(layout.driver) & 1 == 0
      if notify { interrupt() }
    }
    guard final != .broken else { return final }
    if eventIndex {
      memory.store16Release(layout.device + 4 + UInt64(layout.size) * 8, UInt16(nextAvail))
      memory.beforeNotificationCheck()
    }
    // The caller schedules a continuation without waiting for another kick.
    return UInt64(memory.load16Acquire(layout.driver + 2)) != nextAvail ? .reschedule : final
  }
}
