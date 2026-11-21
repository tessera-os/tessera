import TarwinIPC
import TarwinObject

public enum SignalWaitMode: UInt32 { case once, level, edge }
public enum SignalArmResult: Equatable {
  case armed, invalidArgument, invalidHandle, wrongType, denied, limit
}

/// The registry pins the port under its lock, or returns nil for a dead
/// KOID. Wake and port-side callbacks enqueue work, never re-enter locks.
public protocol SignalPorts {
  mutating func withPort<R>(_ id: UInt64, _ body: (inout CompletionPort) -> R) -> R?
  mutating func wake(port: UInt64, count: Int)
}

public struct ObserverSlot {
  fileprivate var next = -1
  fileprivate var port: UInt64 = 0
  fileprivate var operation: PortOperation?
  fileprivate var mask: UInt32 = 0, previous: UInt32 = 0, rising: UInt32 = 0
  fileprivate var mode = SignalWaitMode.once
  public init() {}
}

/// One FIFO beside each observable header; serialize registration and signal
/// mutation with its observer lock. Store only non-reusable KOIDs/tokens for
/// ports: a wait cannot keep the last port handle or event-pair end alive.
public struct SignalObservers: ~Copyable {
  private let object: UnsafePointer<ObjectHeader>
  private let slots: UnsafeMutableBufferPointer<ObserverSlot>
  private var first = -1, last = -1, free: Int
  public private(set) var count = 0

  public init(
    object: UnsafePointer<ObjectHeader>, storage: UnsafeMutableBufferPointer<ObserverSlot>
  ) {
    self.object = object
    slots = storage
    free = storage.isEmpty ? -1 : 0
    for i in storage.indices {
      storage[i] = ObserverSlot()
      storage[i].next = i + 1 < storage.count ? i + 1 : -1
    }
  }

  private mutating func remove(_ i: Int, after prev: Int) {
    if prev >= 0 { slots[prev].next = slots[i].next } else { first = slots[i].next }
    if last == i { last = prev }
    slots[i] = ObserverSlot()
    slots[i].next = free
    free = i
    count -= 1
  }

  /// Under the caller's table writer lock as well as the observer lock:
  /// a close/move cannot slip between validation and port registration.
  public mutating func arm<P: SignalPorts>(
    process: UInt64, source: UInt64, mask: UInt32, mode: SignalWaitMode,
    destination: UInt64, key: UInt64, table: borrowing HandleTable, at now: UInt64, ports: inout P
  ) -> SignalArmResult {
    guard mask != 0, let owner = OperationHandle(process: process, name: source)
    else { return mask == 0 ? .invalidArgument : .invalidHandle }
    switch table.reader.pinWithinEpoch(source, kind: 0, need: 128) {
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .accessDenied: return .denied
    case .found(let ref):
      let same = ref.header == object
      ref.drop { _ in preconditionFailure("lost locked source") }
      guard same else { return .invalidHandle }
    }
    let port: UInt64
    switch table.reader.pinWithinEpoch(destination, kind: TarwinKind.port, need: 0) {
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .accessDenied: return .denied
    case .found(let ref):
      port = ref.header.pointee.koid
      ref.drop { _ in preconditionFailure("lost locked port") }
    }
    guard free >= 0 else { return .limit }
    let id = object.pointee.koid
    guard
      let reservation = ports.withPort(
        port,
        {
          $0.reserve(object: id, key: key, kind: 1, owner: owner, repeating: mode != .once)
        })
    else { return .invalidHandle }
    guard let op = reservation else { return .limit }
    let i = free
    let prev = last
    free = slots[i].next
    slots[i].next = -1
    slots[i].port = port
    slots[i].operation = op
    slots[i].mode = mode
    slots[i].mask = mask
    let signals = object.pointee.signals
    slots[i].previous = signals & mask
    if prev < 0 { first = i } else { slots[prev].next = i }
    last = i
    count += 1
    if !evaluate(i, signals: signals, now: now, ports: &ports) { remove(i, after: prev) }
    return .armed
  }

  private mutating func evaluate<P: SignalPorts>(
    _ i: Int, signals: UInt32, now: UInt64, ports: inout P
  ) -> Bool {
    let s = slots[i]
    let op = s.operation!
    let asserted = signals & s.mask
    var packet = PortPacket()
    if s.mode == .edge {
      slots[i].rising |= asserted & ~s.previous
      slots[i].previous = asserted
      packet.result0 = UInt64(slots[i].rising)
    } else {
      packet.result0 = UInt64(asserted)
    }
    guard packet.result0 != 0 else { return true }
    var wake = 0
    let remains = ports.withPort(s.port) { port in
      if s.mode == .once {
        wake = port.finish(op, at: now) { packet }
        return false
      }
      switch port.more(op, at: now, packet) {
      case .committed(let n):
        wake = n
        slots[i].rising = 0
        return true
      case .inFlight: return true
      case .inactive:
        wake = port.finishCancellation(op, at: now) ?? 0
        return false
      }
    }
    if wake > 0 { ports.wake(port: s.port, count: wake) }
    return remains == true
  }

  public mutating func changed<P: SignalPorts>(at now: UInt64, ports: inout P) {
    let signals = object.pointee.signals
    var i = first
    var prev = -1
    while i >= 0 {
      let next = slots[i].next
      if evaluate(i, signals: signals, now: now, ports: &ports) {
        prev = i
      } else {
        remove(i, after: prev)
      }
      i = next
    }
  }

  private func find(_ op: PortOperation, port: UInt64) -> (index: Int, prev: Int)? {
    var i = first
    var prev = -1
    while i >= 0 {
      if slots[i].operation == op && slots[i].port == port { return (i, prev) }
      prev = i
      i = slots[i].next
    }
    return nil
  }

  /// After consuming MORE (or publishing it to the completion ring), run
  /// the scheduled callback outside the port lock, under the object lock.
  public mutating func consumed<P: SignalPorts>(
    _ op: PortOperation, port: UInt64, at now: UInt64, ports: inout P
  ) {
    guard let (i, prev) = find(op, port: port) else { return }
    if !evaluate(i, signals: object.pointee.signals, now: now, ports: &ports) {
      remove(i, after: prev)
    }
  }

  public mutating func cancelled<P: SignalPorts>(
    _ op: PortOperation, port: UInt64, at now: UInt64, ports: inout P
  ) {
    guard let (i, prev) = find(op, port: port) else { return }
    if let result = ports.withPort(port, { $0.finishCancellation(op, at: now) }) {
      guard let n = result else { return }
      if n > 0 { ports.wake(port: port, count: n) }
    }
    remove(i, after: prev)
  }

  /// Destination vanished: discard rather than publishing a terminal packet.
  public mutating func portClosed(_ op: PortOperation, port: UInt64) {
    if let (i, prev) = find(op, port: port) { remove(i, after: prev) }
  }

  /// Called before the source header or its observer storage can be reclaimed.
  public mutating func destroy<P: SignalPorts>(at now: UInt64, ports: inout P) {
    while first >= 0 {
      let s = slots[first]
      if let result = ports.withPort(
        s.port, { $0.finishCancellation(s.operation!, at: now, destroying: true) }),
        let n = result, n > 0
      {
        ports.wake(port: s.port, count: n)
      }
      remove(first, after: -1)
    }
  }
}
