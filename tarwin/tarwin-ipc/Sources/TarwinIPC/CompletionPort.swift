extension RingRecord {
  fileprivate mutating func pair(_ word: Int, _ value: UInt64) {
    words[word] = UInt32(truncatingIfNeeded: value)
    words[word + 1] = UInt32(value >> 32)
  }
}

/// LibTessera §5.2. Serialize fields explicitly rather than sharing a Swift layout.
public struct PortPacket {
  public var key: UInt64 = 0
  public var error: UInt32 = 0
  public var subsystem: UInt16 = 0
  public var errorFlags: UInt16 = 0
  public var detail: UInt64 = 0
  public var kind: UInt32 = 0
  public var flags: UInt32 = 0
  public var result0: UInt64 = 0
  public var result1: UInt64 = 0
  public var aux: UInt64 = 0
  public var timestamp: UInt64 = 0
  public init() {}

  func record() -> RingRecord {
    var r = RingRecord()
    r.pair(0, key)
    r.words[2] = error
    r.words[3] = UInt32(subsystem) | UInt32(errorFlags) << 16
    r.pair(4, detail)
    r.words[6] = kind
    r.words[7] = flags
    r.pair(8, result0)
    r.pair(10, result1)
    r.pair(12, aux)
    r.pair(14, timestamp)
    return r
  }
}

public struct PortOperation: Equatable {
  fileprivate let index: Int
  fileprivate let serial: UInt64
}

/// The same name (including salt/generation) can exist in two processes.
/// The submitter captures its process KOID and the original object handle
/// under the table epoch; neither field comes from the completion packet.
public struct OperationHandle: Equatable {
  public let process, name: UInt64
  public init?(process: UInt64, name: UInt64) {
    guard process != 0, name != 0 else { return nil }
    self.process = process
    self.name = name
  }
}

public enum PortPulse: Equatable {
  case inactive, inFlight
  case committed(wake: Int)
}

public struct PortSlot {
  fileprivate enum State { case free, spare, pending, cancelling, held, available, inRing }
  fileprivate var state: State = .free
  fileprivate var object: UInt64 = 0, serial: UInt64 = 0
  fileprivate var owner: OperationHandle?
  fileprivate var packet = PortPacket()
  fileprivate var prev = -1, next = -1, list = -1
  fileprivate var credit = -1, subscription = -1
  fileprivate var firstPending = false
  fileprivate var published: UInt32 = 0
  // Each slab index also owns an independent hash bucket of object tails.
  fileprivate var bucketHead = -1, bucketNext = -1
  public init() {}
}

/// One slab per port, held exclusively and serialized by the kernel port lock.
/// A provider retains its port until its callback returns. Operation tokens
/// never cross the ABI and are valid only with the port that issued them.
public struct CompletionPort: ~Copyable {
  private let slots: UnsafeMutableBufferPointer<PortSlot>
  private var free: Int, head = -1, tail = -1
  private var ringHead = -1, ringTail = -1
  private var mapping: UInt?
  private var serial: UInt64 = 0
  public private(set) var available = 0
  public private(set) var closed = false

  public init?(storage: UnsafeMutableBufferPointer<PortSlot>) {
    guard (1...65536).contains(storage.count) else { return nil }
    slots = storage
    free = 0
    for i in storage.indices {
      storage[i] = PortSlot()
      storage[i].list = i + 1 < storage.count ? i + 1 : -1
    }
  }

  private func bucket(_ object: UInt64) -> Int { Int(object % UInt64(slots.count)) }

  /// Replaces an object tail in its hash bucket; chains within one object
  /// maintain submission order independently of other objects.
  private func setTail(object: UInt64, to new: Int) -> Int {
    let b = bucket(object)
    var old = slots[b].bucketHead
    var previous = -1
    while old >= 0 && slots[old].object != object {
      previous = old
      old = slots[old].bucketNext
    }
    let rest = old == -1 ? -1 : slots[old].bucketNext
    if new >= 0 { slots[new].bucketNext = rest }
    let link = new == -1 ? rest : new
    if previous == -1 { slots[b].bucketHead = link } else { slots[previous].bucketNext = link }
    if old >= 0 { slots[old].bucketNext = -1 }
    return old
  }

  private mutating func order(_ i: Int) {
    let old = setTail(object: slots[i].object, to: i)
    slots[i].prev = old
    slots[i].next = -1
    if old >= 0 { slots[old].next = i }
  }

  private mutating func recycle(_ i: Int) {
    let bucketHead = slots[i].bucketHead
    slots[i] = PortSlot()
    slots[i].bucketHead = bucketHead
    slots[i].list = free
    free = i
  }

  /// Reserve the terminal packet and, for a subscription, one reusable MORE
  /// packet. Cancellation never needs to wait for space or discard a packet.
  public mutating func reserve(
    object: UInt64, key: UInt64, kind: UInt32, owner: OperationHandle? = nil,
    repeating: Bool = false
  ) -> PortOperation? {
    guard !closed, free >= 0, !repeating || slots[free].list >= 0, object != 0,
      (1...11).contains(kind), serial != .max
    else {
      return nil
    }
    let i = free
    free = slots[i].list
    serial += 1
    slots[i].state = .pending
    slots[i].object = object
    slots[i].owner = owner
    slots[i].serial = serial
    slots[i].packet.key = key
    slots[i].packet.kind = kind
    if repeating {
      let p = free
      free = slots[p].list
      slots[p].state = .spare
      slots[p].subscription = i
      slots[p].object = object
      slots[i].credit = p
      slots[i].firstPending = true
      order(p)
    } else {
      order(i)
    }
    return PortOperation(index: i, serial: serial)
  }

  /// A provider can commit at most one unread MORE packet. Its first packet
  /// occupies the submission's original position; later pulses are new work.
  public mutating func more(_ op: PortOperation, at now: UInt64, _ packet: PortPacket) -> PortPulse
  {
    let i = op.index
    guard !closed, slots.indices.contains(i), slots[i].serial == op.serial,
      slots[i].state == .pending, slots[i].credit >= 0, packet.error == 0
    else { return .inactive }
    let p = slots[i].credit
    guard slots[p].state == .spare else { return .inFlight }
    if !slots[i].firstPending { order(p) }
    slots[i].firstPending = false
    slots[p].packet = packet
    slots[p].packet.kind = slots[i].packet.kind
    slots[p].packet.key = slots[i].packet.key
    slots[p].packet.flags = 1
    slots[p].packet.timestamp = now
    return .committed(wake: complete(p))
  }

  private mutating func enqueue(_ i: Int) {
    slots[i].state = .available
    slots[i].list = -1
    if tail == -1 { head = i } else { slots[tail].list = i }
    tail = i
    available += 1
  }

  public mutating func post(_ packet: PortPacket) -> Bool {
    guard !closed, free >= 0 else { return false }
    let i = free
    free = slots[i].list
    slots[i].packet = packet
    slots[i].packet.kind = 0
    enqueue(i)
    return true
  }

  /// The callback schedules backend cancellation; it must not re-enter
  /// this port. Publish Cancelled only after the backend stops using buffers.
  public mutating func cancel(key: UInt64, schedule: (PortOperation) -> Void) -> Int {
    cancelWithSource(key: key) { _, op in schedule(op) }
  }

  public mutating func cancelWithSource(
    key: UInt64, schedule: (UInt64, PortOperation) -> Void
  ) -> Int {
    cancel(where: { $0.packet.key == key }, schedule: schedule)
  }

  /// Resolve a queued provider callback to its immutable source object.
  public func source(of op: PortOperation) -> UInt64? {
    let i = op.index
    guard !closed, slots.indices.contains(i), slots[i].serial == op.serial,
      slots[i].state == .pending || slots[i].state == .cancelling
    else { return nil }
    return slots[i].object
  }

  /// A detached observer may be destroyed without a prior Port.cancel.
  /// Do not turn an unsolicited cancellation acknowledgement into success.
  public mutating func finishCancellation(
    _ op: PortOperation, at now: UInt64, destroying: Bool = false
  ) -> Int? {
    guard source(of: op) != nil, destroying || slots[op.index].state == .cancelling
    else { return nil }
    slots[op.index].state = .cancelling
    return finish(op, at: now) { preconditionFailure("cancelled operation committed a result") }
  }

  /// Closing, replacing or transferring one name does not cancel work
  /// submitted through a duplicate or through a different process's table.
  public mutating func cancel(owner: OperationHandle, schedule: (PortOperation) -> Void) -> Int {
    cancel(where: { $0.owner == owner }) { _, op in schedule(op) }
  }

  private mutating func cancel(
    where matches: (PortSlot) -> Bool,
    schedule: (UInt64, PortOperation) -> Void
  ) -> Int {
    guard !closed else { return 0 }
    var count = 0
    for i in slots.indices where slots[i].state == .pending && matches(slots[i]) {
      slots[i].state = .cancelling
      count += 1
      schedule(slots[i].object, PortOperation(index: i, serial: slots[i].serial))
    }
    return count
  }

  /// A provider calls this once after its last buffer access. The returned
  /// count is the number of newly deliverable packets (wake one waiter each).
  /// Commit a result (e.g. install a returned handle) only if still live.
  public mutating func finish(_ op: PortOperation, at now: UInt64, result: () -> PortPacket) -> Int
  {
    var i = op.index
    guard !closed, slots.indices.contains(i), slots[i].serial == op.serial,
      slots[i].state == .pending || slots[i].state == .cancelling
    else { return 0 }
    let key = slots[i].packet.key
    let kind = slots[i].packet.kind
    let cancelled = slots[i].state == .cancelling
    let p = slots[i].credit
    if p >= 0 {
      slots[p].subscription = -1
      if slots[i].firstPending {
        // Finish in our reserved order position, without emitting MORE.
        recycle(i)
        i = p
      } else {
        if slots[p].state == .spare { recycle(p) }
        slots[i].credit = -1
        order(i)
      }
    }
    if cancelled {
      slots[i].packet = PortPacket()
      slots[i].packet.error = 26
      slots[i].packet.subsystem = 1
    } else {
      slots[i].packet = result()
      if slots[i].packet.error != 0 { slots[i].packet.result0 = 0 }
    }
    slots[i].packet.timestamp = now
    slots[i].packet.key = key
    slots[i].packet.kind = kind
    slots[i].packet.flags = 0
    return complete(i)
  }

  private mutating func complete(_ i: Int) -> Int {
    slots[i].state = .held
    guard slots[i].prev == -1 else { return 0 }
    let before = available
    var j = i
    while j >= 0 && slots[j].state == .held {
      let next = slots[j].next
      if next == -1 {
        _ = setTail(object: slots[j].object, to: -1)
      } else {
        slots[next].prev = -1
      }
      enqueue(j)
      j = next
    }
    return available - before
  }

  private mutating func unlinkHead() -> Int {
    let i = head
    head = slots[i].list
    if head == -1 { tail = -1 }
    available -= 1
    return i
  }

  private mutating func consumed(_ i: Int, _ rearm: (PortOperation) -> Void) {
    let s = slots[i].subscription
    if s >= 0 {
      slots[i].state = .spare
      if slots[s].state == .pending { rearm(PortOperation(index: s, serial: slots[s].serial)) }
    } else {
      recycle(i)
    }
  }

  /// Queue re-evaluation after dequeue; the callback must not re-enter this port.
  public mutating func take(rearm: (PortOperation) -> Void = { _ in }) -> PortPacket? {
    guard head >= 0 else { return nil }
    let packet = slots[head].packet
    consumed(unlinkHead(), rearm)
    return packet
  }

  /// One bound, pinned completion ring per port. Retain a subscription's
  /// unread credit until the *consumer* acknowledges its sequence.
  public mutating func acknowledgeConsumed(
    from ring: inout RingEndpoint, rearm: (PortOperation) -> Void
  ) -> RingStep? {
    guard ring.isPortCompletionProducer, mapping == nil || mapping == ring.completionMapping
    else { return .wrongSide }
    guard let seen = ring.consumedThrough() else { return .invalidPeer }
    while ringHead >= 0 && slots[ringHead].published <= seen {
      let i = ringHead
      ringHead = slots[i].list
      if ringHead == -1 { ringTail = -1 }
      consumed(i, rearm)
    }
    return nil
  }

  /// Leave the packet queued on backpressure, malformed cursors or a wrong endpoint.
  public mutating func publishNext(
    to ring: inout RingEndpoint, rearm: (PortOperation) -> Void = { _ in }
  ) -> RingStep? {
    if let error = acknowledgeConsumed(from: &ring, rearm: rearm) { return error }
    guard head >= 0 else { return nil }
    let result = ring.push(slots[head].packet.record())
    if case .transferred = result {
      mapping = ring.completionMapping
      let i = unlinkHead()
      if slots[i].subscription >= 0 {
        slots[i].state = .inRing
        slots[i].published = ring.publishedThrough
        slots[i].list = -1
        if ringTail == -1 { ringHead = i } else { slots[ringTail].list = i }
        ringTail = i
      } else {
        recycle(i)
      }
    }
    return result
  }

  /// Closing the port discards results; it does not cancel backend I/O.
  public mutating func close(disarmSignal: (UInt64, PortOperation) -> Void = { _, _ in }) {
    guard !closed else { return }
    closed = true
    for i in slots.indices {
      if slots[i].packet.kind == 1 && (slots[i].state == .pending || slots[i].state == .cancelling)
      {
        disarmSignal(slots[i].object, PortOperation(index: i, serial: slots[i].serial))
      }
      slots[i] = PortSlot()
    }
    available = 0
    head = -1
    tail = -1
    ringHead = -1
    ringTail = -1
  }
}
