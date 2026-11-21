// The caller serializes volume access. The private 4 KiB scratch page stays
// mapped and exclusive until the volume is released; it is never driver DMA.
public protocol TrfsMedia {
  var blocks: UInt64 { get }
  func read(_ block: UInt64, into: UnsafeMutableRawBufferPointer) -> Bool
  func write(_ block: UInt64, from: UnsafeRawBufferPointer) -> Bool
  func flush() -> Bool
  func sha256(_ bytes: UnsafeRawBufferPointer) -> TrfsDigest
}

public struct TrfsDigest: Equatable {
  fileprivate let a, b, c, d: UInt64
  public init?(_ bytes: UnsafeRawBufferPointer) {
    guard bytes.count == 32 else { return nil }
    self.init(bytes, 0)
  }
  fileprivate init(_ bytes: UnsafeRawBufferPointer, _ at: Int) {
    a = bytes.word(at)
    b = bytes.word(at + 8)
    c = bytes.word(at + 16)
    d = bytes.word(at + 24)
  }
  private init() {
    a = 0
    b = 0
    c = 0
    d = 0
  }
  fileprivate static var zero: Self { Self() }
  public func encode(into bytes: UnsafeMutableRawBufferPointer) -> Bool {
    guard bytes.count == 32 else { return false }
    put(bytes, 0)
    return true
  }
  fileprivate func put(_ p: UnsafeMutableRawBufferPointer, _ at: Int) {
    p.put(at, a)
    p.put(at + 8, b)
    p.put(at + 16, c)
    p.put(at + 24, d)
  }
}

extension UnsafeRawBufferPointer {
  // All callers have checked the exact sector size or 32-byte digest width.
  fileprivate func word(_ at: Int) -> UInt64 {
    UInt64(littleEndian: loadUnaligned(fromByteOffset: at, as: UInt64.self))
  }
}
extension UnsafeMutableRawBufferPointer {
  fileprivate func put(_ at: Int, _ value: UInt64) {
    storeBytes(of: value.littleEndian, toByteOffset: at, as: UInt64.self)
  }
}

public struct TrfsSnapshot: Equatable {
  public let digest: TrfsDigest
  fileprivate let block: UInt64
  fileprivate init(_ block: UInt64, _ digest: TrfsDigest) {
    self.block = block
    self.digest = digest
  }
  fileprivate init(_ p: UnsafeRawBufferPointer, _ at: Int) {
    self.init(p.word(at), TrfsDigest(p, at + 8))
  }
  fileprivate static var empty: Self { Self(0, .zero) }
  fileprivate func put(_ p: UnsafeMutableRawBufferPointer, _ at: Int) {
    p.put(at, block)
    digest.put(p, at + 8)
  }
  fileprivate func valid(before end: UInt64) -> Bool {
    self == .empty || (block >= 2 && block < end && digest != .zero)
  }
}
private struct Anchor {
  var generation: UInt64, tail: UInt64, head: TrfsSnapshot
}
/// In-memory write binding, not a wire type. The same immutable root may
/// be published again by a branch or reopened after an uncertain flush.
struct TrfsPublication: Equatable {
  fileprivate let mount, generation: UInt64
  let root: TrfsSnapshot
}
public enum TrfsLookup: Equatable {
  case absent
  case file(UInt64)
  case directory(UInt64)
  case symlink(UInt64)
  case damaged
}
public enum TrfsNodeKind: UInt8 {
  case file = 1
  case directory = 2
  case symlink = 3
}

public enum TrfsRenameMode { case noReplace, replace, exchange }
public enum TrfsResizeResult: Equatable { case ok, busy, outOfRange, failed }

public struct TrfsVolume<M: TrfsMedia>: ~Copyable {
  private let io: M, page: UnsafeMutableRawBufferPointer
  private var state: Anchor?, next: UInt64 = 0, readonly = false, incarnation: UInt64 = 0
  private var systemAttempted = false
  private var p: UnsafeRawBufferPointer { .init(page) }
  private static var anchorMagic: UInt64 { 0x0001_0000_5346_5254 }  // TRFS, v1 at byte 6
  private static var nodeMagic: UInt64 { 0x0001_0000_4e46_5254 }  // TRFN
  public var snapshot: TrfsSnapshot? { state?.head }
  var publication: TrfsPublication? {
    guard let state, !readonly else { return nil }
    return .init(mount: incarnation, generation: state.generation, root: state.head)
  }
  var canPublish: Bool { writable != nil }
  public init?(media: M, scratch: UnsafeMutableRawBufferPointer) {
    guard media.blocks >= 4, scratch.count == 4096, scratch.baseAddress != nil else { return nil }
    self.io = media
    self.page = scratch
  }
  private func clear() { for i in page.indices { page[i] = 0 } }
  private func blank(_ from: Int, _ to: Int) -> Bool {
    for i in from..<to where page[i] != 0 { return false }
    return true
  }
  private func publish(_ a: Anchor) -> Bool {
    clear()
    page.put(0, Self.anchorMagic)
    page.put(8, a.generation)
    page.put(16, a.tail)
    page.put(24, io.blocks)
    a.head.put(page, 32)
    io.sha256(.init(rebasing: p[..<4064])).put(page, 4064)
    return io.write(a.generation & 1, from: p) && io.flush()
  }
  /// Format only provisioned zero anchors. Ordinary mount never formats.
  public mutating func formatBlank() -> Bool {
    guard !systemAttempted, state == nil, incarnation < .max else { return false }
    for slot in UInt64(0)...1 {
      guard io.read(slot, into: page), blank(0, 4096) else { return false }
    }
    let a = Anchor(generation: 1, tail: 2, head: .empty)
    guard publish(a) else { return false }
    incarnation += 1
    state = a
    next = a.tail
    readonly = false
    return true
  }
  /// With a pinned digest, open an integrity-checked read-only snapshot.
  /// The system boot path uses mountSystem to require measurement as well.
  public mutating func mount(expected: TrfsDigest? = nil) -> Bool {
    guard !systemAttempted, let a = select(expected: expected) else { return false }
    install(a, readonly: expected != nil)
    return true
  }
  /// Consume one boot attempt. The caller takes the expected hash from the
  /// verified slot's immutable boot set. Its measurement provider must commit
  /// the digest to PCR 11 and publish the matching log event before success.
  public mutating func mountSystem(
    expected: TrfsDigest, measure: (TrfsDigest) -> Bool
  ) -> Bool {
    mountSystem(root: expected, measure: measure)
  }
  /// Input from the boot-set verifier, not a disk field or path. Bad length
  /// consumes this attempt too; a missing root must not select an unpinned mount.
  public mutating func mountSystem(
    bootSetRoot bytes: UnsafeRawBufferPointer, measure: (TrfsDigest) -> Bool
  ) -> Bool {
    mountSystem(root: TrfsDigest(bytes), measure: measure)
  }
  private mutating func mountSystem(
    root: TrfsDigest?, measure: (TrfsDigest) -> Bool
  ) -> Bool {
    guard state == nil, !systemAttempted else { return false }
    systemAttempted = true
    guard let root, let a = select(expected: root), measure(a.head.digest) else { return false }
    install(a, readonly: true)
    return true
  }
  private func select(expected: TrfsDigest?) -> Anchor? {
    guard state == nil, incarnation < .max else { return nil }
    var selected: Anchor?
    for slot in UInt64(0)...1 {
      guard io.read(slot, into: page) else { return nil }
      if blank(0, 4096) { continue }
      guard io.sha256(.init(rebasing: p[..<4064])) == TrfsDigest(p, 4064) else { continue }
      let a = Anchor(generation: p.word(8), tail: p.word(16), head: .init(p, 32))
      guard p.word(0) == Self.anchorMagic, p.word(24) == io.blocks, blank(72, 4064),
        a.generation != 0, a.generation & 1 == slot, a.tail >= 2, a.tail <= io.blocks,
        a.head.valid(before: a.tail)
      else { return nil }
      if a.generation > (selected?.generation ?? 0) { selected = a }
    }
    guard let a = selected, expected == nil || (a.head != .empty && expected == a.head.digest),
      a.head == .empty || record(a.head)
    else { return nil }
    return a
  }
  private mutating func install(_ a: Anchor, readonly: Bool) {
    state = a
    incarnation += 1
    self.readonly = readonly
    next = a.tail
  }

  private func read(_ ref: TrfsSnapshot) -> Bool {
    ref.block >= 2 && ref.block < io.blocks && io.read(ref.block, into: page)
      && io.sha256(p) == ref.digest
  }
  private func record(_ r: TrfsSnapshot) -> Bool {
    guard read(r), p.word(0) == Self.nodeMagic, p.word(8) != 0,
      TrfsSnapshot(p, 32).valid(before: r.block)
    else { return false }
    let nameBytes = Int(page[114])
    guard blank(115, 128), blank(128 + nameBytes, 4096) else { return false }
    let blob = TrfsSnapshot(p, 72)
    switch page[112] {
    case 1:  // directory entry, zero target = whiteout
      return blob == .empty && p.word(16) == 0 && page[113] == 0 && nameBytes > 0
        && Self.validName(UnsafeRawBufferPointer(rebasing: p[128..<(128 + nameBytes)]))
    case 2:  // inode, value = size
      if page[113] == TrfsNodeKind.symlink.rawValue {
        return nameBytes == 0 && p.word(16) == 0 && (1...4096).contains(p.word(24))
          && blob != .empty && blob.valid(before: r.block)
      }
      return blob == .empty && nameBytes == 0 && p.word(16) == 0
        && (page[113] == 1 || (page[113] == 2 && p.word(24) == 0))
    case 3:  // data page
      return nameBytes == 0 && page[113] == 0 && p.word(24) == 0 && blob != .empty
        && blob.valid(before: r.block)
    case 4:  // truncate: older full pages at or above key are holes
      return nameBytes == 0 && page[113] == 0 && p.word(24) == 0 && blob == .empty
        && p.word(16) <= (UInt64.max / 4096) + 1
    default: return false
    }
  }
  private static func validName(_ bytes: UnsafeRawBufferPointer) -> Bool {
    guard bytes.count > 0 && bytes.count <= 255 else { return false }
    var dotsOnly = bytes.count <= 2
    for i in 0..<bytes.count {
      let b = bytes[i]
      if b < 32 || b == 47 { return false }
      if b != 46 { dotsOnly = false }
    }
    return !dotsOnly
  }

  // nil = media/integrity failure, false = absent. Strictly decreasing
  // backward references bound the walk without consuming kernel stack.
  private func seek(
    _ root: TrfsSnapshot, _ tag: UInt8, _ id: UInt64,
    _ index: UInt64 = 0, _ name: UnsafeRawBufferPointer = .init(start: nil, count: 0)
  ) -> Bool? {
    var r = root
    while r != .empty {
      guard record(r) else { return nil }
      if tag == 3 && page[112] == 4 && p.word(8) == id && index >= p.word(16) {
        return false
      }
      if page[112] == tag && p.word(8) == id && p.word(16) == index && name.count == Int(page[114])
      {
        var matches = true
        for i in 0..<name.count where name[i] != page[128 + i] { matches = false; break }
        if matches { return true }
      }
      r = .init(p, 32)
    }
    return false
  }

  private func inode(_ id: UInt64, _ root: TrfsSnapshot) -> (TrfsNodeKind, UInt64)? {
    guard let a = state, root.valid(before: a.tail), !readonly || root == a.head else { return nil }
    if id == 1 { return (.directory, 0) }
    guard id > 1, seek(root, 2, id) == true, let k = TrfsNodeKind(rawValue: page[113]) else {
      return nil
    }
    return (k, p.word(24))
  }
  public func lookup(_ parent: UInt64, name: [UInt8], in root: TrfsSnapshot) -> TrfsLookup {
    name.withUnsafeBytes { lookup(parent, nameBytes: $0, in: root) }
  }
  /// Borrow a name outside the volume's scratch page for the duration of the walk.
  public func lookup(_ parent: UInt64, nameBytes name: UnsafeRawBufferPointer, in root: TrfsSnapshot) -> TrfsLookup {
    guard Self.validName(name), inode(parent, root)?.0 == .directory,
      let found = seek(root, 1, parent, 0, name)
    else { return .damaged }
    guard found else { return .absent }
    let id = p.word(24)
    if id == 0 { return .absent }
    guard let k = inode(id, root)?.0 else { return .damaged }
    switch k {
    case .file: return .file(id)
    case .directory: return .directory(id)
    case .symlink: return .symlink(id)
    }
  }
  private static func validTarget(_ target: [UInt8]) -> Bool {
    guard !target.isEmpty, target.count <= 4096 else { return false }
    var n = 0
    for b in target {
      if b == 47 {
        guard n > 0 else { return false }
        n = 0
      } else {
        guard b >= 32, n < 255 else { return false }
        n += 1
      }
    }
    return n > 0
  }
  private func target(of link: UInt64, in root: TrfsSnapshot) -> [UInt8]? {
    guard let (kind, length) = inode(link, root), kind == .symlink,
      read(.init(p, 72)), blank(Int(length), 4096)
    else { return nil }
    let bytes = Array(p[..<Int(length)])
    return Self.validTarget(bytes) ? bytes : nil
  }
  /// The caller resolves the authorized Node to its volume and local inode
  /// first. Link targets cannot pop above that original capability.
  public func resolve(
    from node: UInt64, relative: [UInt8], followLinks: Bool, in root: TrfsSnapshot
  ) -> Walk {
    guard let (kind, _) = inode(node, root) else { return .damaged }
    if relative.isEmpty { return .found(node) }
    guard kind == .directory else { return .notDirectory }
    return scopedLookup(node, relative, followLinks) { parent, name in
      switch lookup(parent, name: name, in: root) {
      case .absent: return .missing
      case .damaged: return .damaged
      case .directory(let id): return .directory(id)
      case .file(let id): return .file(id)
      case .symlink(let id):
        guard let bytes = target(of: id, in: root) else { return .damaged }
        return .symlink(bytes)
      }
    }
  }
  private mutating func appendPage(_ bytes: UnsafeRawBufferPointer) -> TrfsSnapshot? {
    guard next < io.blocks, bytes.count == 4096 else { return nil }
    let r = TrfsSnapshot(next, io.sha256(bytes))
    guard r.digest != .zero, io.write(next, from: bytes) else { return nil }
    next += 1
    return r
  }
  private mutating func append(
    _ prev: TrfsSnapshot, tag: UInt8, id: UInt64, key: UInt64 = 0,
    value: UInt64 = 0, name: [UInt8] = [], kind: UInt8 = 0,
    blob: TrfsSnapshot = .empty
  ) -> TrfsSnapshot? {
    clear()
    page.put(0, Self.nodeMagic)
    page.put(8, id)
    page.put(16, key)
    page.put(24, value)
    prev.put(page, 32)
    blob.put(page, 72)
    page[112] = tag
    page[113] = kind
    page[114] = UInt8(name.count)
    for i in name.indices { page[128 + i] = name[i] }
    return appendPage(p)
  }
  private var writable: Anchor? {
    guard !readonly, let a = state, a.generation < .max else { return nil }
    return a
  }
  private mutating func commit(_ head: TrfsSnapshot, _ base: Anchor) -> Bool {
    let a = Anchor(generation: base.generation + 1, tail: next, head: head)
    // An indeterminate anchor write/flush requires a fresh mount. In
    // particular don't reuse blocks on the basis of an old in-memory head.
    state = nil
    guard io.flush(), publish(a) else { return false }
    state = a
    return true
  }
  public mutating func create(_ parent: UInt64, name: [UInt8], kind: TrfsNodeKind) -> UInt64? {
    guard kind != .symlink, let a = writable, lookup(parent, name: name, in: a.head) == .absent
    else { return nil }
    let id = next
    guard let i = append(a.head, tag: 2, id: id, kind: kind.rawValue),
      let d = append(i, tag: 1, id: parent, value: id, name: name), commit(d, a)
    else { return nil }
    return id
  }
  /// Publish target, inode and name together. Targets may be dangling.
  public mutating func createSymlink(_ parent: UInt64, name: [UInt8], target: [UInt8]) -> UInt64? {
    guard let a = writable, Self.validTarget(target),
      lookup(parent, name: name, in: a.head) == .absent
    else { return nil }
    clear()
    for i in target.indices { page[i] = target[i] }
    guard let blob = appendPage(p) else { return nil }
    let id = next
    guard let i = append(a.head, tag: 2, id: id, value: UInt64(target.count),
      kind: TrfsNodeKind.symlink.rawValue, blob: blob),
      let d = append(i, tag: 1, id: parent, value: id, name: name), commit(d, a)
    else { return nil }
    return id
  }
  private func nonDirectory(_ entry: TrfsLookup) -> UInt64? {
    switch entry {
    case .file(let id), .symlink(let id): return id
    default: return nil
    }
  }
  /// The namespace caller checks source Delete, destination Create, and
  /// destination Delete when displacing an entry. Never follow either link.
  public mutating func moveFile(
    _ parent: UInt64, name: [UInt8], to dir: UInt64, as dest: [UInt8],
    mode: TrfsRenameMode = .noReplace
  ) -> Bool {
    guard let a = writable, let id = nonDirectory(lookup(parent, name: name, in: a.head))
    else { return false }
    if parent == dir && name == dest { return mode != .noReplace }
    let other = lookup(dir, name: dest, in: a.head)
    let replacement: UInt64
    switch (mode, other) {
    case (.noReplace, .absent), (.replace, .absent), (.replace, .file), (.replace, .symlink):
      replacement = 0
    case (.exchange, .file(let second)), (.exchange, .symlink(let second)):
      replacement = second
    default: return false
    }
    guard let first = append(a.head, tag: 1, id: parent, value: replacement, name: name),
      let added = append(first, tag: 1, id: dir, value: id, name: dest)
    else { return false }
    return commit(added, a)
  }
  public mutating func unlinkFile(_ parent: UInt64, name: [UInt8]) -> Bool {
    guard let a = writable, nonDirectory(lookup(parent, name: name, in: a.head)) != nil,
      let removed = append(a.head, tag: 1, id: parent, name: name)
    else { return false }
    return commit(removed, a)
  }
  public func length(_ file: UInt64, in root: TrfsSnapshot) -> UInt64? {
    guard let (k, n) = inode(file, root), k == .file else { return nil }
    return n
  }
  /// Caller holds Write and serializes the VM range lock with publication.
  /// Check actual live mappings before shrinking, not just active I/O leases.
  public mutating func resize(
    _ file: UInt64, to size: UInt64, limit: UInt64, isUnmapped: (Range<UInt64>) -> Bool
  ) -> TrfsResizeResult {
    guard size <= limit else { return .outOfRange }
    guard let a = writable, let old = length(file, in: a.head) else { return .failed }
    if old == size { return .ok }
    var head = a.head
    if size < old {
      guard isUnmapped(size..<old) else { return .busy }
      let index = size / 4096, tail = Int(size % 4096)
      if tail > 0 {
        guard let found = seek(head, 3, file, index) else { return .failed }
        if found {
          guard read(.init(p, 72)), blank(Int(min(4096, old - index * 4096)), 4096)
          else { return .failed }
          for i in tail..<4096 { page[i] = 0 }
          guard let blob = appendPage(p),
            let map = append(head, tag: 3, id: file, key: index, blob: blob)
          else { return .failed }
          head = map
        }
      }
      guard let barrier = append(head, tag: 4, id: file, key: index + (tail == 0 ? 0 : 1))
      else { return .failed }
      head = barrier
    }
    guard let inode = append(head, tag: 2, id: file, value: size, kind: 1), commit(inode, a)
    else { return .failed }
    return .ok
  }
  /// src is private cache memory, disjoint from volume scratch. Bytes past
  /// EOF are always canonical zeros; callers may extend sparsely.
  public mutating func writePage(_ file: UInt64, index: UInt64, bytes: UnsafeRawBufferPointer)
    -> Bool
  {
    guard bytes.count <= 4096, let p = publication else { return false }
    return writeFrame(file, index: index, bytes: bytes, expected: p)
  }

  /// Publish up to one VM frame with a single anchor flip. On a stale
  /// writable binding or failed publication, no partial page becomes visible.
  mutating func writeFrame(
    _ file: UInt64, index: UInt64, bytes: UnsafeRawBufferPointer,
    expected: TrfsPublication
  ) -> Bool {
    guard let a = writable, publication == expected, let size = length(file, in: a.head),
      bytes.count > 0, bytes.count <= 16384, index <= (.max - UInt64(bytes.count)) / 4096
    else { return false }
    let end = index * 4096 + UInt64(bytes.count)
    guard bytes.count % 4096 == 0 || end >= size else { return false }
    var head = a.head
    for pos in stride(from: 0, to: bytes.count, by: 4096) {
      clear()
      page.copyMemory(from: .init(rebasing: bytes[pos..<min(bytes.count, pos + 4096)]))
      guard let blob = appendPage(p),
        let data = append(head, tag: 3, id: file, key: index + UInt64(pos / 4096), blob: blob)
      else { return false }
      head = data
    }
    guard let i = append(head, tag: 2, id: file, value: max(size, end), kind: 1)
    else { return false }
    return commit(i, a)
  }
  /// Returns valid bytes (including zero for EOF); errors never expose a
  /// partial or unauthenticated block. dst and scratch must not alias.
  public func readPage(
    _ file: UInt64, index: UInt64, in root: TrfsSnapshot,
    into dst: UnsafeMutableRawBufferPointer
  ) -> Int? {
    guard dst.count == 4096, index <= .max / 4096, let size = length(file, in: root) else {
      return nil
    }
    let offset = index * 4096
    let valid = offset >= size ? 0 : Int(min(size - offset, 4096))
    if valid > 0 {
      guard let found = seek(root, 3, file, index) else { return nil }
      if found {
        guard read(.init(p, 72)), blank(valid, 4096) else { return nil }
        dst.copyMemory(from: p)
        return valid
      }
    }
    for i in dst.indices { dst[i] = 0 }
    return valid
  }
  /// Clone an issued snapshot in O(1), retaining the allocation high-water
  /// mark. The caller binds roots to the same volume and authorizes rollback.
  public mutating func branch(from root: TrfsSnapshot) -> Bool {
    guard let a = writable, root.valid(before: a.tail), root == .empty || record(root) else {
      return false
    }
    return commit(root, a)
  }
}
