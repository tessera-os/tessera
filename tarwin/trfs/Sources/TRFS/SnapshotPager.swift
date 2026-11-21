/// Trusted VM bindings. Lookup is relative to this mount's immutable snapshot,
/// not a user-supplied inode number. Private frame mappings remain pinned
/// until release, which scrubs them even after a partially failed load.
public protocol TrfsSnapshotFrames {
  func file(for object: UInt64) -> UInt64?
  func mayWrite(_ object: UInt64) -> Bool
  mutating func acquire(_ bytes: UInt64) -> UInt64?
  func mapping(_ physical: UInt64) -> UnsafeMutableRawBufferPointer?
  mutating func release(_ physical: UInt64, bytes: UInt64)
}
extension TrfsSnapshotFrames {
  public func mayWrite(_ object: UInt64) -> Bool { false }
}

/// The volume and snapshot outlive the pager; hold its sleepable mount lock
/// over every fault. No version substitution between validating size and load.
public struct TrfsSnapshotStore<M: TrfsMedia, F: TrfsSnapshotFrames>: TrfsPageStore {
  private let volume: UnsafePointer<TrfsVolume<M>>, writer: UnsafeMutablePointer<TrfsVolume<M>>?
  private var root: TrfsSnapshot
  private var binding: TrfsPublication?
  private var frames: F
  public init(volume: UnsafePointer<TrfsVolume<M>>, root: TrfsSnapshot, frames: F) {
    self.volume = volume
    self.writer = nil
    self.root = root
    self.frames = frames
  }
  /// Exclusive, serialized writable mount. This store owns its committed head;
  /// changes made through any other publisher invalidate it, never rebase dirty data.
  public init?(writer: UnsafeMutablePointer<TrfsVolume<M>>, frames: F) {
    guard writer.pointee.canPublish, let current = writer.pointee.publication else { return nil }
    self.volume = UnsafePointer(writer)
    self.writer = writer
    self.root = current.root
    self.binding = current
    self.frames = frames
  }
  private var current: Bool {
    guard let writer else { return true }
    return binding != nil && writer.pointee.publication == binding
  }
  public func mayFault(object: UInt64, write: Bool) -> Bool {
    current && (!write || (writer?.pointee.canPublish == true && frames.mayWrite(object)))
      && frames.file(for: object) != nil
  }
  public mutating func acquireFrame(bytes: UInt64) -> UInt64? { frames.acquire(bytes) }
  public func load(object: UInt64, offset: UInt64, valid: UInt64, into frame: UInt64) -> Bool {
    guard current, let file = frames.file(for: object), let dst = frames.mapping(frame),
      dst.count == 4096 || dst.count == 16384, offset % UInt64(dst.count) == 0,
      let size = volume.pointee.length(file, in: root), offset < size,
      valid == min(size - offset, UInt64(dst.count))
    else { return false }
    var n = 0
    while n < Int(valid) {
      let part = UnsafeMutableRawBufferPointer(rebasing: dst[n..<(n + 4096)])
      guard
        volume.pointee.readPage(file, index: (offset + UInt64(n)) / 4096, in: root, into: part)
          == min(4096, Int(valid) - n)
      else { return false }
      n += 4096
    }
    return true
  }
  public func clear(frame: UInt64, from: UInt64, to: UInt64) {
    guard let dst = frames.mapping(frame), from <= to, to <= dst.count else { return }
    for i in Int(from)..<Int(to) { dst[i] = 0 }
  }
  public mutating func store(object: UInt64, offset: UInt64, valid: UInt64, from frame: UInt64)
    -> Bool
  {
    guard let writer, let binding, mayFault(object: object, write: true),
      let file = frames.file(for: object),
      let src = frames.mapping(frame), src.count == 4096 || src.count == 16384,
      offset % UInt64(src.count) == 0, let size = volume.pointee.length(file, in: root),
      offset < size, valid == min(size - offset, UInt64(src.count)),
      writer.pointee.writeFrame(
        file, index: offset / 4096,
        bytes: .init(rebasing: UnsafeRawBufferPointer(src)[..<Int(valid)]), expected: binding),
      let next = writer.pointee.publication
    else { return false }
    self.binding = next
    root = next.root
    return true
  }
  public mutating func releaseFrame(_ frame: UInt64, bytes: UInt64) {
    frames.release(frame, bytes: bytes)
  }
}
