import TarwinABI
import TarwinObject
import TarwinSched

public enum ChannelEnd { case a, b }

/// The owner serializes pair operations and keeps both distinct headers
/// mapped for the pair's lifetime. Retire callbacks only enqueue destruction:
/// they must not synchronously reacquire process or channel locks.
public struct ChannelPair: ~Copyable {
  private var toA: ChannelQueue, toB: ChannelQueue
  private let a: UnsafePointer<ObjectHeader>, b: UnsafePointer<ObjectHeader>

  public init?(
    a: UnsafePointer<ObjectHeader>, b: UnsafePointer<ObjectHeader>,
    toA: consuming ChannelQueue, toB: consuming ChannelQueue
  ) {
    guard a != b, a.pointee.kind == TarwinKind.channel, b.pointee.kind == TarwinKind.channel else {
      return nil
    }
    self.a = a
    self.b = b
    self.toA = toA
    self.toB = toB
    refresh()
  }

  public func peek(at end: ChannelEnd) -> ChannelSize? {
    end == .a ? toA.nextSize : toB.nextSize
  }

  private func waitingEndpoint(at end: ChannelEnd) -> UInt64? {
    switch end {
    case .a: return toA.count == 0 && toA.writable ? a.pointee.koid : nil
    case .b: return toB.count == 0 && toB.writable ? b.pointee.koid : nil
    }
  }

  func serviceOpen(_ id: UInt64) -> Bool? {
    guard id == a.pointee.koid || id == b.pointee.koid else { return nil }
    return !toA.senderClosed && !toA.receiverClosed && !toB.senderClosed && !toB.receiverClosed
  }

  /// The service owner holds the channel lock across parking the receiver
  /// and publishing its pinned per-thread message area.
  public func waitForRequest(
    at end: ChannelEnd, into area: ServiceArea, cpu: inout BootstrapCPU, now: UInt64
  )
    -> WaitingService?
  {
    guard let endpoint = waitingEndpoint(at: end), let wait = cpu.waitForService(endpoint, now: now)
    else { return nil }
    return WaitingService(wait: wait, area: area)
  }

  /// An older queued message always wins. On nil nothing was sent: continue
  /// through the ordinary channel path, including its handle error semantics.
  public func directCall(
    from end: ChannelEnd, waiting: WaitingService,
    transaction: UInt64, deadline: UInt64, now: UInt64, cpu: inout BootstrapCPU,
    message: ServiceMessage, replyTo area: ServiceArea, sender: inout HandleTable,
    receiver: inout HandleTable, invalidate: (UInt64) -> Void
  ) -> DirectServiceCall? {
    guard transaction != 0, deadline == .max || now < deadline, sender.owns(area.table),
      !receiver.owns(area.table),
      let endpoint = waitingEndpoint(at: end == .a ? .b : .a),
      let loan = cpu.call(
        endpoint, waiting: waiting.wait, now: now,
        deliver: {
          message.deliver(
            to: waiting.area, sender: &sender, receiver: &receiver, invalidate: invalidate)
        })
    else { return nil }
    return DirectServiceCall(
      loan: loan, transaction: transaction, deadline: deadline,
      replyArea: area, serverTable: waiting.area.table)
  }

  /// Exclusively owned, unpublished pair. The caller holds the child task,
  /// job, staging/child table and channel locks. Staging names are selected
  /// and narrowed by trusted launch policy, never by a user-provided header.
  /// Success moves them into B's only message and closes A for further sends.
  public mutating func preloadStartup(
    child: inout ProcessExecution, tree: borrowing JobTree, app: UInt64, flags: UInt32,
    tags: UnsafeBufferPointer<UInt32>, names: UnsafeBufferPointer<UInt64>,
    staging: inout HandleTable, scratch: UnsafeMutableRawBufferPointer,
    invalidate: (UInt64) -> Void, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ChildBootstrap? {
    let member = child.member
    let childMap = child.initialMap
    guard child.phase == .created, b.pointee.ownerJob == child.job.id,
      toA.writable, toB.writable, toA.count == 0, toB.count == 0, tags.count == names.count,
      let id = StartupIdentity(flags: flags, app: app, process: member.id, job: child.job.id),
      let size = id.encode(tags: tags, into: scratch)
    else { return nil }
    let bytes = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(scratch)[..<size])
    return child.withHandles(tree: tree) { table -> ChildBootstrap? in
      guard table.count == 0, table.freeCount > names.count,
        case .installed(let name) = table.install(b, rights: 1 << 2)
      else { return nil }
      let result = send(
        from: .a, bytes, names: names, table: &staging,
        invalidate: invalidate, retire: retire)
      guard result == .ok else {
        _ = table.close(name, retire: retire)
        return nil
      }
      close(.a, retire: retire)
      return ChildBootstrap(
        process: member, initialMap: childMap, endpoint: b.pointee.koid, name: name)
    } ?? nil
  }

  /// Validate immediately before constructing the first frame, under the same
  /// locks, for the child whose VM root is being installed. No pointer escapes.
  public func entryName(
    _ token: ChildBootstrap, child: borrowing ProcessExecution,
    tree: borrowing JobTree, initialMap: UInt64? = nil
  ) -> UInt64? {
    guard token.process == child.member, token.initialMap == initialMap,
      initialMap == child.initialMap,
      token.endpoint == b.pointee.koid,
      tree.returnGate(child.member) == .run, toB.senderClosed, toB.count == 1, toB.readable,
      child.soleStartupHandle(token.name, channel: b)
    else { return nil }
    return token.name
  }

  public mutating func send(
    from end: ChannelEnd, _ bytes: UnsafeRawBufferPointer,
    names: UnsafeBufferPointer<UInt64>, table: inout HandleTable,
    invalidate: (UInt64) -> Void,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> ChannelStatus {
    let result: ChannelStatus
    switch end {
    case .a:
      result = toB.write(bytes, names: names, from: &table, invalidate: invalidate, retire: retire)
    case .b:
      result = toA.write(bytes, names: names, from: &table, invalidate: invalidate, retire: retire)
    }
    refresh()
    return result
  }

  public mutating func receive(
    at end: ChannelEnd, into bytes: UnsafeMutableRawBufferPointer,
    names: UnsafeMutableBufferPointer<UInt64>, table: inout HandleTable, size: inout ChannelSize
  ) -> ChannelStatus {
    let result: ChannelStatus
    switch end {
    case .a: result = toA.read(into: bytes, names: names, to: &table, size: &size)
    case .b: result = toB.read(into: bytes, names: names, to: &table, size: &size)
    }
    refresh()
    return result
  }

  public mutating func close(_ end: ChannelEnd, retire: (UnsafePointer<ObjectHeader>) -> Void) {
    switch end {
    case .a:
      toA.closeReceiver(retire: retire)
      toB.closeSender()
    case .b:
      toB.closeReceiver(retire: retire)
      toA.closeSender()
    }
    refresh()
  }

  private func refresh() {
    set(a, incoming: toA, outgoing: toB)
    set(b, incoming: toB, outgoing: toA)
  }

  private func set(
    _ header: UnsafePointer<ObjectHeader>, incoming: borrowing ChannelQueue,
    outgoing: borrowing ChannelQueue
  ) {
    let state: UInt32 =
      (incoming.readable ? 1 : 0) | (outgoing.writable ? 2 : 0) | (incoming.senderClosed ? 4 : 0)
    if header.pointee.signals & 7 != state {
      _ = header.pointee.updateSignals(clear: 7, set: state)
    }
  }
}

/// Only a successful preload can construct this witness. It neither
/// authenticates an image nor owns a VM root; the launch owner binds those.
public struct ChildBootstrap {
  fileprivate let process: ProcessKey
  fileprivate let initialMap: UInt64?
  fileprivate let endpoint, name: UInt64
}
