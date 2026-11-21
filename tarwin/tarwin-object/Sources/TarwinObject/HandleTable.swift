import Synchronization

/// Kernel-owned transfer descriptor. Drop or move the reference exactly once.
/// Never construct this from user data.
public struct ObjectGrant: ~Copyable {
  public let header: UnsafePointer<ObjectHeader>
  public let rights: UInt64

  // The final releaser schedules destruction; storage is freed after the epoch.
  public consuming func drop(retire: (UnsafePointer<ObjectHeader>) -> Void) {
    if header.pointee.release() == .destroy { retire(header) }
  }
}

public struct HandleCell: ~Copyable {
  fileprivate let published = Atomic<UInt64>(0)
  fileprivate let object = Atomic<UnsafeRawPointer?>(nil)
  fileprivate let rights = Atomic<UInt64>(0)
  fileprivate var generation: UInt64 = 1
  fileprivate var next: Int
  fileprivate init(next: Int) { self.next = next }
}

public enum PinResult: ~Copyable {
  case invalidHandle, wrongType, accessDenied
  case found(ObjectGrant)
}

public struct HandleReadView {
  fileprivate let cells: UnsafeBufferPointer<HandleCell>

  /// Hold the process table's read epoch for the entire call. The table
  /// and retired object headers must remain mapped until that epoch drains.
  /// A successful result is independently pinned and may leave the epoch.
  public func pinWithinEpoch(_ name: UInt64, kind: UInt32, need: UInt64) -> PinResult {
    let i = Int(handleIndex(name))
    guard name != 0, i < cells.count, let base = cells.baseAddress else { return .invalidHandle }
    let cell = base + i
    guard cell.pointee.published.load(ordering: .sequentiallyConsistent) == name else {
      return .invalidHandle
    }
    let rights = cell.pointee.rights.load(ordering: .sequentiallyConsistent)
    guard let raw = cell.pointee.object.load(ordering: .sequentiallyConsistent),
      cell.pointee.published.load(ordering: .sequentiallyConsistent) == name
    else { return .invalidHandle }
    let header = raw.assumingMemoryBound(to: ObjectHeader.self)
    guard kind == 0 || kind == header.pointee.kind else { return .wrongType }
    guard rights & need == need else { return .accessDenied }
    guard header.pointee.retainIfLive() else { return .invalidHandle }
    return .found(ObjectGrant(header: header, rights: rights))
  }
}

public enum HandleMutation {
  case invalidHandle, accessDenied, limit
  case installed(UInt64)
}

public enum MoveInstallResult: ~Copyable {
  case limit(ObjectGrant)
  case installed(UInt64)
}

/// One writer under the process table lock; lock-free readers hold a separate
/// immutable view. Capacity and salt are fixed at process creation. The caller
/// supplies stable uninitialized storage, drains under the writer lock, waits
/// for the last read epoch, then deinitializes and frees that storage.
public struct HandleTable: ~Copyable {
  private let cells: UnsafeMutableBufferPointer<HandleCell>
  private let salt: UInt8
  private var first = 0
  private var unused: Int
  private var limit: Int
  public private(set) var count = 0
  public var freeCount: Int { min(unused, max(0, limit - count)) }
  mutating func tighten(to maximum: UInt32) { limit = min(limit, Int(maximum)) }

  public init?(storage: UnsafeMutableBufferPointer<HandleCell>, salt: UInt8) {
    guard storage.count > 0, storage.count <= Int(HandleLayout.maximumSlots),
      let base = storage.baseAddress
    else { return nil }
    self.cells = storage
    self.salt = salt
    self.unused = storage.count
    self.limit = storage.count
    for i in 0..<storage.count {
      (base + i).initialize(to: HandleCell(next: i + 1 == storage.count ? -1 : i + 1))
    }
  }

  public var reader: HandleReadView { HandleReadView(cells: UnsafeBufferPointer(cells)) }

  func contains(_ name: UInt64) -> Bool { live(name) != nil }

  private func live(_ name: UInt64) -> UnsafeMutablePointer<HandleCell>? {
    let i = Int(handleIndex(name))
    guard name != 0, i < cells.count, let base = cells.baseAddress else { return nil }
    let c = base + i
    return c.pointee.published.load(ordering: .sequentiallyConsistent) == name ? c : nil
  }

  private mutating func publish(_ grant: consuming ObjectGrant) -> UInt64 {
    let i = first
    let c = cells.baseAddress! + i
    first = c.pointee.next
    unused -= 1
    count += 1
    let name = UInt64(salt) << 56 | c.pointee.generation << 20 | UInt64(i)
    c.pointee.object.store(UnsafeRawPointer(grant.header), ordering: .sequentiallyConsistent)
    c.pointee.rights.store(grant.rights, ordering: .sequentiallyConsistent)
    c.pointee.published.store(name, ordering: .sequentiallyConsistent)
    return name
  }

  /// Takes its own reference only on success; caller retains its input.
  public mutating func install(_ header: UnsafePointer<ObjectHeader>, rights: UInt64)
    -> HandleMutation
  {
    guard rights & header.pointee.maximumRights == rights else { return .accessDenied }
    guard freeCount > 0 else { return .limit }
    guard header.pointee.retainIfLive() else { return .invalidHandle }
    return .installed(publish(ObjectGrant(header: header, rights: rights)))
  }

  private func snapshot(_ c: UnsafeMutablePointer<HandleCell>) -> (
    header: UnsafePointer<ObjectHeader>, rights: UInt64
  ) {
    let raw = c.pointee.object.load(ordering: .sequentiallyConsistent)!
    return (
      raw.assumingMemoryBound(to: ObjectHeader.self),
      c.pointee.rights.load(ordering: .sequentiallyConsistent)
    )
  }

  private mutating func remove(_ c: UnsafeMutablePointer<HandleCell>, index: Int) -> ObjectGrant {
    let held = snapshot(c)
    c.pointee.published.store(0, ordering: .sequentiallyConsistent)
    c.pointee.object.store(nil, ordering: .sequentiallyConsistent)
    c.pointee.rights.store(0, ordering: .sequentiallyConsistent)
    count -= 1
    if c.pointee.generation != HandleLayout.lastGeneration {
      c.pointee.generation += 1
      c.pointee.next = first
      first = index
      unused += 1
    }
    return ObjectGrant(header: held.header, rights: held.rights)
  }

  public mutating func installMoved(_ grant: consuming ObjectGrant) -> MoveInstallResult {
    guard freeCount > 0 else { return .limit(grant) }
    return .installed(publish(grant))
  }

  public mutating func close(_ name: UInt64, retire: (UnsafePointer<ObjectHeader>) -> Void) -> Bool
  {
    guard let c = live(name) else { return false }
    remove(c, index: Int(handleIndex(name))).drop(retire: retire)
    return true
  }

  public mutating func derive(_ name: UInt64, rights: UInt64, duplicate: Bool) -> HandleMutation {
    guard let c = live(name) else { return .invalidHandle }
    let source = snapshot(c)
    guard handleMayDerive(source.rights, rights, duplicate) else { return .accessDenied }
    let reduced = rights == UInt64.max ? source.rights : rights
    if duplicate { return install(source.header, rights: reduced) }
    // Replacement normally reuses the old slot, even when the table is full.
    guard unused > 0 || c.pointee.generation < HandleLayout.lastGeneration else { return .limit }
    let held = remove(c, index: Int(handleIndex(name)))
    return .installed(publish(ObjectGrant(header: held.header, rights: reduced)))
  }

  /// Names are an immutable kernel-private copy. Preflight the entire batch
  /// before moving any references. The receiver of a moved grant must either
  /// transfer it onward or drop it, including on backpressure or peer death.
  public mutating func moveForChannel(
    _ names: UnsafeBufferPointer<UInt64>,
    invalidate: (UInt64) -> Void = { _ in },
    take: (consuming ObjectGrant) -> Void
  ) -> HandleCheck {
    guard names.count <= 64 else { return .invalidHandle }
    for i in names.indices {
      guard let c = live(names[i]) else { return .invalidHandle }
      guard c.pointee.rights.load(ordering: .sequentiallyConsistent) & 2 != 0 else {
        return .accessDenied
      }
      for j in 0..<i where names[i] == names[j] { return .invalidHandle }
    }
    for name in names {
      let grant = remove(live(name)!, index: Int(handleIndex(name)))
      invalidate(name)
      take(grant)
    }
    return .allowed
  }

  public mutating func drain(
    invalidate: (UInt64) -> Void = { _ in }, retire: (UnsafePointer<ObjectHeader>) -> Void
  ) {
    for i in 0..<cells.count {
      let c = cells.baseAddress! + i
      let name = c.pointee.published.load(ordering: .sequentiallyConsistent)
      if name != 0 {
        let grant = remove(c, index: i)
        invalidate(name)
        grant.drop(retire: retire)
      }
    }
  }
}
