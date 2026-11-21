// Virtio 1.3 §5.3. Single port, two queues, no multiport control messages,
// size configuration or emergency-write register.
public struct VirtioConsole {
  public let function: VirtioPCIFunction
  private let backend: ConsoleBackend

  public init?(queueSize: UInt16, vectors: UInt16, host: any ConsoleHost) {
    let backend = ConsoleBackend(host)
    guard
      let function = VirtioPCIFunction(
        device: 3, classCode: 0x078000, features: 1 << 32, queues: [queueSize, queueSize],
        vectors: vectors, configLength: 0, backend: backend)
    else { return nil }
    self.backend = backend
    self.function = function
    backend.function = function
  }

  // Called on the serialized VM device loop after a readiness or continuation event.
  @discardableResult public func resume(queue: Int) -> Bool {
    guard function.common.transport.ready(), function.common.queues.indices.contains(queue)
    else { return false }
    return backend.kick(queue: queue, layout: function.common.queues[queue])
  }

  static func transfer(queue: Int, segments: [Segment], host: any ConsoleHost) -> QueueTransfer {
    guard queue == 0 || queue == 1 else { return .invalid }
    var size: UInt64 = 0
    for span in segments {
      guard span.writable == (queue == 0), span.length <= DeviceIoLimit.bytes - size,
        span.length == 0 || span.length - 1 <= UInt64.max - span.address
      else { return .invalid }
      size += span.length
    }
    guard size != 0 else { return .complete(0) }
    return host.withPinnedPayload(segments) {
      if queue == 0 {
        let bytes = host.receive(Int(size))
        guard !bytes.isEmpty else { return .waitForHost }
        guard scatterDeviceReply(segments, bytes, host.writeByte) else { return .invalid }
        return .complete(UInt64(bytes.count))
      }
      guard let bytes = gatherDeviceRequest(segments, host.readByte) else { return .invalid }
      return host.transmit(bytes) ? .complete(0) : .waitForHost
    }
  }
}

// One VM's pinned RAM and grant-scoped port. reset drains I/O and drops ring
// pins and watchers. schedule enqueues (never reenters); when waiting, arm a
// level-triggered host readiness event so an already-ready port isn't missed.
public protocol ConsoleHost: AnyObject, PinnedQueueMemory {
  var ram: GuestAperture { get }
  func pin(queue: Int, layout: SplitQueueLayout) -> Bool
  func reset() -> Bool
  func setBusMaster(_ enabled: Bool) -> Bool
  func withPinnedPayload(_ spans: [Segment], _ body: () -> QueueTransfer) -> QueueTransfer
  func readByte(_ address: UInt64) -> UInt8
  func writeByte(_ address: UInt64, _ value: UInt8)
  // Both calls are nonblocking. receive returns at most capacity bytes;
  // transmit accepts all bytes, or none and returns false.
  func receive(_ capacity: Int) -> [UInt8]
  func transmit(_ bytes: [UInt8]) -> Bool
  func schedule(queue: Int, waitingForPort: Bool)
  func inject(message: UInt64, data: UInt32) -> Bool
  func setINTx(asserted: Bool)
}

private final class ConsoleBackend: VirtioPCIBackend {
  let host: any ConsoleHost
  weak var function: VirtioPCIFunction?
  var pumps: [QueuePump?] = [nil, nil]
  var master = false
  var ram: GuestAperture { host.ram }

  init(_ host: any ConsoleHost) { self.host = host }
  func pin(queue: Int, layout: SplitQueueLayout) -> Bool {
    guard pumps.indices.contains(queue), pumps[queue] == nil, host.pin(queue: queue, layout: layout)
    else { return false }
    pumps[queue] = QueuePump(slots: Int(layout.size))
    return true
  }
  func reset() -> Bool {
    guard host.reset() else { return false }
    pumps = [nil, nil]
    return true
  }
  func setBusMaster(_ enabled: Bool) -> Bool {
    guard host.setBusMaster(enabled) else { return false }
    master = enabled
    if enabled {
      for q in pumps.indices where pumps[q] != nil {
        host.schedule(queue: q, waitingForPort: false)
      }
    }
    return true
  }
  func kick(queue: Int, layout: SplitQueueLayout) -> Bool {
    guard master, let function, pumps.indices.contains(queue), var pump = pumps[queue]
    else { return false }
    var delivered = true
    let r = pump.notify(
      layout, in: ram, eventIndex: false, memory: host,
      attempt: { VirtioConsole.transfer(queue: queue, segments: $0, host: host) },
      interrupt: { delivered = function.queueInterrupt(queue) })
    pumps[queue] = pump
    if r == .waiting || r == .reschedule {
      host.schedule(queue: queue, waitingForPort: r == .waiting)
    }
    return r != .broken && delivered
  }
  func inject(message: UInt64, data: UInt32) -> Bool { host.inject(message: message, data: data) }
  func setINTx(asserted: Bool) { host.setINTx(asserted: asserted) }
  func readConfig(offset: Int, width: Int) -> UInt64? { nil }
  func writeConfig(offset: Int, width: Int, value: UInt64) -> Bool { false }
}
