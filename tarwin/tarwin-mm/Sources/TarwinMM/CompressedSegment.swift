import KCore

public struct CompressedSlot: IntrusiveNode {
  public var listLink = IntrusiveLink()
  fileprivate var serial: UInt64 = 0
  fileprivate var offset = 0, size = 0
  fileprivate var tagged = false
  public init() {}
}

/// A kernel-private backing reference, not a user handle. Never reuse a
/// segment identity, even when reinitializing the same physical frame.
public struct CompressedPage {
  fileprivate let segment, serial: UInt64
  fileprivate let slot: Int
  public let storedBytes: UInt64
}

private struct SegmentBytes: ByteBuffer {
  let bytes: UnsafeMutableBufferPointer<UInt8>
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
  mutating func putByte(_ offset: UInt64, value: UInt8) { bytes[Int(offset)] = value }
}

/// One wired base page of raw LZ4 blocks. The caller exclusively owns the
/// segment lock, backing page and at most 64 metadata slots. Frame, tags
/// and codec scratch must be pinned and disjoint from each other and storage.
public struct CompressedSegment: ~Copyable {
  private let id: UInt64
  private let storage: UnsafeMutableBufferPointer<UInt8>
  private let slots: UnsafeMutableBufferPointer<CompressedSlot>
  private var free: IntrusiveList<CompressedSlot>
  public private(set) var usedBytes = 0
  private var serial: UInt64 = 0

  public init?(identity: UInt64, storage: UnsafeMutableBufferPointer<UInt8>,
    slots: UnsafeMutableBufferPointer<CompressedSlot>) {
    guard identity != 0, storage.count == 4096 || storage.count == 16384,
      (1...64).contains(slots.count) else { return nil }
    for i in slots.indices { slots[i] = CompressedSlot() }
    guard var list = IntrusiveList(nodes: slots) else { return nil }
    for i in slots.indices.reversed() {
      guard list.prepend(i) else { return nil }
    }
    id = identity
    self.storage = storage
    self.slots = slots
    free = consume list
  }

  /// The source is frozen under its object lock. Do not recycle its frame
  /// before installing the returned reference and draining all translations.
  public mutating func store<S: ByteSource, H: MatchTable>(
    _ frame: S, tagged: Bool, table: inout H
  ) -> CompressedPage? {
    guard frame.byteCount() == frameBytes(UInt64(storage.count), tagged: tagged),
      usedBytes < storage.count, serial != .max, free.first != nil else { return nil }
    // Do not publish a block that costs as much as its resident data page.
    let capacity = min(storage.count - usedBytes, storage.count - 1)
    var tail = SegmentBytes(bytes: .init(start: storage.baseAddress! + usedBytes, count: capacity))
    let result = compressPage(frame, output: &tail, table: &table)
    guard result.ok, let i = free.popFirst() else { return nil }
    serial += 1
    slots[i].serial = serial
    slots[i].offset = usedBytes
    slots[i].size = Int(result.count)
    slots[i].tagged = tagged
    usedBytes += Int(result.count)
    return CompressedPage(segment: id, serial: serial, slot: i, storedBytes: result.count)
  }

  private func slot(_ ref: CompressedPage) -> CompressedSlot? {
    guard ref.segment == id, slots.indices.contains(ref.slot),
      slots[ref.slot].serial == ref.serial else { return nil }
    return slots[ref.slot]
  }

  /// Restore into an unpublished exclusive frame (plus packed allocation tags
  /// for tagged pages). Keep the old reference on any failure, including a
  /// failed PTE installation after this method returns.
  public func restore<D: ByteBuffer>(_ ref: CompressedPage, into frame: inout D, tagged: Bool) -> Bool {
    guard let s = slot(ref), s.tagged == tagged else { return false }
    let logical = frameBytes(UInt64(storage.count), tagged: tagged)
    guard frame.byteCount() == logical else { return false }
    let source = SegmentBytes(bytes: .init(start: storage.baseAddress! + s.offset, count: s.size))
    return decompressPage(source, stored: UInt64(s.size), output: &frame, logical: logical)
  }

  /// Called after the owner no longer references this block. Move the tail
  /// down in place; surviving references name slots, not offsets.
  public mutating func discard(_ ref: CompressedPage) -> Bool {
    guard let s = slot(ref), free.prepend(ref.slot) else { return false }
    for src in (s.offset + s.size)..<usedBytes { storage[src - s.size] = storage[src] }
    let end = usedBytes - s.size
    for i in end..<usedBytes { storage[i] = 0 }
    for i in slots.indices where slots[i].serial != 0 && slots[i].offset > s.offset {
      slots[i].offset -= s.size
    }
    slots[ref.slot].serial = 0
    usedBytes = end
    return true
  }
}
