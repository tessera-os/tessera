import TarwinReadOnlyFS

public struct ArchiveNode: ReadOnlyNode {
  public let id: UInt64, name: String, size: Int, directory: Bool
  fileprivate let data: UInt64
}

private struct Component: Hashable {
  let parent: UInt64, bytes: [UInt8]
}

private func octal(_ b: ArraySlice<UInt8>) throws -> UInt64 {
  let field = b.drop(while: { $0 == 32 })
  let digits = field.prefix { (48...55).contains($0) }
  guard !digits.isEmpty, field.dropFirst(digits.count).allSatisfy({ $0 == 0 || $0 == 32 })
  else { throw VolumeError.invalidMedia }
  // Only the 8-byte checksum and 12-byte size fields enter here.
  return digits.reduce(0) { $0 * 8 + UInt64($1 - 48) }
}

private func text(_ field: ArraySlice<UInt8>) throws -> [UInt8] {
  let bytes = field.prefix { $0 != 0 }
  guard field.dropFirst(bytes.count).allSatisfy({ $0 == 0 }) else { throw VolumeError.invalidMedia }
  return Array(bytes)
}

private func componentName(_ b: [UInt8]) throws -> String {
  guard (1...255).contains(b.count), b != [46], b != [46, 46],
    b.allSatisfy({ $0 >= 32 && $0 != 47 && $0 != 127 }),
    let name = String(validating: b, as: UTF8.self)
  else { throw VolumeError.invalidName }
  return name
}

/// Read-only uncompressed POSIX ustar files and directories. Build the
/// whole namespace before admitting the mount. Never extract to a host path;
/// reads address only offsets in the same immutable media snapshot.
public struct UstarVolume<M: VolumeMedia>: ReadOnlyVolume {
  public let root: UInt64 = 1
  public static var maxNameBytes: UInt32 { 255 }
  private let media: M, nodes: [ArchiveNode], children: [Component: UInt64],
    order: [UInt64: [UInt64]]

  public init(_ media: M) throws {
    let length = media.byteCount
    guard length >= 1024, length % 512 == 0 else { throw VolumeError.invalidMedia }
    func read(_ at: UInt64, _ count: Int) throws -> [UInt8] {
      guard at <= length, UInt64(count) <= length - at else { throw VolumeError.invalidMedia }
      guard let b = media.read(at: at, count: count), b.count == count else { throw VolumeError.io }
      return b
    }
    var nodes = [ArchiveNode(id: 1, name: "", size: 0, directory: true, data: 0)]
    var children: [Component: UInt64] = [:]
    var order: [UInt64: [UInt64]] = [:]
    var explicit = Set<UInt64>()
    var offset: UInt64 = 0
    var headers = 0
    while true {
      let b = try read(offset, 512)
      offset += 512
      if b.allSatisfy({ $0 == 0 }) {
        // Two zero records followed only by bounded zero tape padding.
        let remaining = length - offset
        guard remaining >= 512, remaining <= 1 << 20,
          try read(offset, Int(remaining)).allSatisfy({ $0 == 0 })
        else { throw VolumeError.invalidMedia }
        break
      }
      headers += 1
      guard headers <= 65536 else { throw VolumeError.tooLarge }
      guard b[257..<265].elementsEqual([117, 115, 116, 97, 114, 0, 48, 48]),
        b[157..<257].allSatisfy({ $0 == 0 }), [0, 48, 53].contains(b[156])
      else { throw VolumeError.invalidMedia }
      var sum: UInt64 = 8 * 32
      for i in b.indices where !(148..<156).contains(i) { sum += UInt64(b[i]) }
      guard try octal(b[148..<156]) == sum else { throw VolumeError.invalidMedia }
      let size = try octal(b[124..<136])
      let directory = b[156] == 53
      let padded = (size + 511) & ~511
      guard !directory || size == 0, padded <= length - offset else {
        throw VolumeError.invalidMedia
      }
      let prefix = try text(b[345..<500])
      let leaf = try text(b[0..<100])
      guard !leaf.isEmpty else { throw VolumeError.invalidName }
      var path = prefix.isEmpty ? leaf : prefix + [47] + leaf
      if directory && path.last == 47 { path.removeLast() }
      if path == [46], directory {
        guard explicit.insert(1).inserted else { throw VolumeError.invalidMedia }
        continue
      }
      if path.starts(with: [46, 47]) { path.removeFirst(2) }
      let parts = path.split(separator: 47, omittingEmptySubsequences: false)
      guard !path.isEmpty, parts.count <= 64 else { throw VolumeError.invalidName }
      var parent: UInt64 = 1
      for (i, part) in parts.enumerated() {
        let raw = Array(part)
        let name = try componentName(raw)
        let end = i + 1 == parts.count
        let key = Component(parent: parent, bytes: raw)
        let id: UInt64
        if let existing = children[key] {
          guard nodes[Int(existing) - 1].directory, !end || directory else {
            throw VolumeError.invalidMedia
          }
          id = existing
        } else {
          guard nodes.count < 65536 else { throw VolumeError.tooLarge }
          id = UInt64(nodes.count) + 1
          let dir = !end || directory
          nodes.append(
            ArchiveNode(
              id: id, name: name, size: dir ? 0 : Int(size), directory: dir, data: dir ? 0 : offset)
          )
          children[key] = id
          order[parent, default: []].append(id)
        }
        if end && !explicit.insert(id).inserted { throw VolumeError.invalidMedia }
        parent = id
      }
      offset += padded
    }
    self.media = media
    self.nodes = nodes
    self.children = children
    self.order = order
  }

  public func node(_ id: UInt64) throws -> ArchiveNode {
    guard id > 0, id <= UInt64(nodes.count) else { throw VolumeError.notFound }
    return nodes[Int(id) - 1]
  }
  public func entry(parent: UInt64, index: UInt64) throws -> ArchiveNode? {
    guard try node(parent).directory else { throw VolumeError.notDirectory }
    guard let ids = order[parent], index < UInt64(ids.count) else { return nil }
    return try node(ids[Int(index)])
  }
  public func lookup(parent: UInt64, name: [UInt8]) throws -> UInt64 {
    guard try node(parent).directory else { throw VolumeError.notDirectory }
    _ = try componentName(name)
    guard let id = children[Component(parent: parent, bytes: name)] else {
      throw VolumeError.notFound
    }
    return id
  }
  public func bytes(node id: UInt64, offset: UInt64, count: Int) throws -> [UInt8] {
    let file = try node(id)
    guard !file.directory else { throw VolumeError.isDirectory }
    guard (0...(1 << 20)).contains(count) else { throw VolumeError.tooLarge }
    guard offset < UInt64(file.size), count > 0 else { return [] }
    let n = min(count, file.size - Int(offset))
    guard let bytes = media.read(at: file.data + offset, count: n), bytes.count == n else {
      throw VolumeError.io
    }
    return bytes
  }
}
