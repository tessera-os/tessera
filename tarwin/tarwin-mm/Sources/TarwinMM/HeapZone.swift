import KCore

/// Out-of-line metadata for a provisioned slab. No links or type information
/// are stored in allocator clients' writable bytes.
public struct HeapSlab {
  fileprivate var start: UInt = 0
  fileprivate var sizeClass: UInt = 0
  fileprivate var typeID: UInt64 = 0
  fileprivate var slots: Int = 0
  fileprivate var ready: UInt64 = 0
  fileprivate var live: UInt64 = 0
  fileprivate var pending: UInt64 = 0
  fileprivate var draining: UInt64 = 0
  public init() {}
}

public enum HeapTagPolicy {
  case noHardwareTags
  case synchronousMTE
}

public struct HeapQuarantineBatch {
  fileprivate let owner: UInt
  fileprivate let serial: UInt64
}

/// A serialized, non-sleeping small-object arena. Provision virtual ranges
/// only while bootstrapping/refilling. Never remap an issued range to another
/// zone, even after every object in the zone has been freed.
public struct HeapArena: ~Copyable {
  private let bytes: UnsafeMutableRawBufferPointer
  private let slabs: UnsafeMutableBufferPointer<HeapSlab>
  private var tail: UInt
  private var used = 0
  private var epoch: UInt64 = 0
  private var inFlight = false

  /// Both mappings are exclusively owned for the arena lifetime, never shared
  /// with users or other arenas. Storage stays bound to this allocator and its
  /// zone keys for the lifetime of the kernel VA reservation. Metadata must be
  /// initialized, disjoint from storage, and not accessible to object clients.
  /// Select policy from admitted CPU features; never substitute quarantine on MTE.
  @unsafe public init?(
    storage: UnsafeMutableRawBufferPointer,
    metadata: UnsafeMutableBufferPointer<HeapSlab>, policy: HeapTagPolicy
  ) {
    guard case .noHardwareTags = policy, let base = storage.baseAddress,
      let m = metadata.baseAddress, metadata.count > 0, metadata.count <= 4096, storage.count >= 16
    else { return nil }
    let p = UInt(bitPattern: base)
    let q = UInt(bitPattern: m)
    let n = UInt(storage.count)
    let z = UInt(metadata.count * MemoryLayout<HeapSlab>.stride)
    guard n <= UInt.max - p, z <= UInt.max - q, p + n <= q || q + z <= p else { return nil }
    bytes = storage
    slabs = metadata
    tail = p
  }

  /// The complete TIR typeid is the bucket key: no two distinct keys share a
  /// slab. There is no operation to remove a slab or change its key.
  public mutating func provision(typeID: UInt64, sizeClass: Int, slots: Int) -> Bool {
    guard (16...65536).contains(sizeClass), isPowerOfTwo(UInt64(sizeClass)),
      (1...64).contains(slots), used < slabs.count
    else { return false }
    let stride = UInt(sizeClass)
    let size = stride * UInt(slots)
    let end = UInt(bitPattern: bytes.baseAddress!) + UInt(bytes.count)
    let skip = (0 &- tail) & (stride - 1)
    guard skip <= end - tail, size <= end - tail - skip else { return false }
    var slab = HeapSlab()
    slab.start = tail + skip
    slab.sizeClass = stride
    slab.typeID = typeID
    slab.slots = slots
    slab.ready = slots == 64 ? .max : (1 << slots) - 1
    slabs[used] = slab
    used += 1
    tail = slab.start + size
    return true
  }

  /// AnyContext fast path for the boot CPU or an exclusively locked arena.
  /// Never wait or provision on the allocation path. The caller performs job
  /// charging and must not publish the object until initialization completes.
  @unsafe public mutating func allocate(size: Int, alignment: Int, typeID: UInt64)
    -> UnsafeMutableRawPointer?
  {
    guard size > 0, size <= 65536, alignment > 0, alignment <= 65536,
      isPowerOfTwo(UInt64(alignment))
    else { return nil }
    var stride = UInt(max(16, alignment))
    while stride < UInt(size) { stride <<= 1 }
    for i in 0..<used
    where slabs[i].sizeClass == stride && slabs[i].typeID == typeID && slabs[i].ready != 0 {
      let slot = slabs[i].ready.trailingZeroBitCount
      let bit: UInt64 = 1 << slot
      let ptr = UnsafeMutableRawPointer(bitPattern: slabs[i].start + UInt(slot) * stride)!
      slabs[i].ready &= ~bit
      slabs[i].live |= bit
      clear(ptr, count: Int(stride))
      return ptr
    }
    return nil
  }

  /// Only a live, exact slot start can be returned. The client has already
  /// destroyed/deinitialized the object and excluded all further accesses.
  @unsafe public mutating func free(_ ptr: UnsafeMutableRawPointer) -> Bool {
    let p = UInt(bitPattern: ptr)
    for i in 0..<used where p >= slabs[i].start {
      let stride = slabs[i].sizeClass
      let offset = p - slabs[i].start
      if offset >= UInt(slabs[i].slots) * stride { continue }
      guard offset & (stride - 1) == 0 else { return false }
      let bit = UInt64(1) << (offset / stride)
      guard slabs[i].live & bit != 0 else { return false }
      slabs[i].live &= ~bit
      clear(ptr, count: Int(stride))
      slabs[i].pending |= bit
      return true
    }
    return false
  }

  private func clear(_ p: UnsafeMutableRawPointer, count: Int) {
    // Exact, exclusively owned slot, with no live/bound object.
    for i in 0..<count { p.storeBytes(of: UInt8(0), toByteOffset: i, as: UInt8.self) }
  }

  /// Freeze a batch before starting its external quarantine/grace interval.
  /// Subsequent frees can only enter the next batch.
  public mutating func beginQuarantine() -> HeapQuarantineBatch? {
    guard !inFlight, epoch < .max else { return nil }
    var any = false
    for i in 0..<used {
      slabs[i].draining = slabs[i].pending
      any = any || slabs[i].draining != 0
      slabs[i].pending = 0
    }
    guard any else { return nil }
    inFlight = true
    epoch += 1
    return HeapQuarantineBatch(owner: UInt(bitPattern: slabs.baseAddress!), serial: epoch)
  }

  /// Called by the quarantine owner, once its grace interval for this exact
  /// arena/batch has elapsed. Never drain merely because allocation failed.
  public mutating func completeQuarantine(_ ticket: HeapQuarantineBatch) -> Bool {
    guard inFlight, epoch == ticket.serial, ticket.owner == UInt(bitPattern: slabs.baseAddress!)
    else { return false }
    for i in 0..<used {
      slabs[i].ready |= slabs[i].draining
      slabs[i].draining = 0
    }
    inFlight = false
    return true
  }
}
