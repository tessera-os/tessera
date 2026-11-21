import TarwinReadOnlyFS

public struct ExFatNode: ReadOnlyNode {
  public let id: UInt64, name: String, size: Int, directory: Bool
  fileprivate let initialized: Int, chain: [Int]
}
private struct Component: Hashable { let parent: UInt64, upper: [UInt16] }

private func checkedName(_ words: [UInt16]) throws -> String {
  guard !words.isEmpty, words.count <= 255, words != [46], words != [46, 46],
    !words.contains(where: { $0 < 32 || [34, 42, 47, 58, 60, 62, 63, 92, 124].contains($0) })
  else { throw VolumeError.invalidName }
  let s = String(decoding: words, as: UTF16.self)
  guard s.utf16.elementsEqual(words), s.utf8.count <= 255 else { throw VolumeError.invalidName }
  return s
}

/// Read-only single-FAT 1.00 media. Index everything before publishing the
/// root: a later cross-linked stream must invalidate the entire mount.
public struct ExFatVolume<M: VolumeMedia>: ReadOnlyVolume {
  public static var maxNameBytes: UInt32 { 255 }
  public let root: UInt64 = 1
  private let disk: ExDisk<M>, upper: [UInt16], nodes: [ExFatNode], children: [Component: UInt64],
    order: [UInt64: [UInt64]]
  public init(_ media: M) throws {
    let disk = try ExDisk(media)
    var owned = Set<Int>()
    let rootChain = try disk.chain(first: disk.root, length: nil, contiguous: false, owned: &owned)
    let rootBytes = try disk.read(rootChain, count: rootChain.count * disk.clusterBytes)
    var bitmapOffset: Int?
    var caseOffset: Int?
    for i in stride(from: 0, to: rootBytes.count, by: 32) {
      if rootBytes[i] == 0 { break }
      if rootBytes[i] == 0x81 {
        guard bitmapOffset == nil, rootBytes[i + 1] == 0 else { throw VolumeError.invalidMedia }
        bitmapOffset = i
      } else if rootBytes[i] == 0x82 {
        guard caseOffset == nil else { throw VolumeError.invalidMedia }
        caseOffset = i
      }
    }
    guard let bi = bitmapOffset, let ci = caseOffset,
      le(rootBytes, bi + 24, 8) == UInt64((disk.clusters + 7) / 8),
      le(rootBytes, ci + 24, 8) <= 131072
    else { throw VolumeError.invalidMedia }
    func metadata(_ i: Int) throws -> [UInt8] {
      let length = le(rootBytes, i + 24, 8)
      let c = try disk.chain(
        first: Int(le(rootBytes, i + 20, 4)), length: length, contiguous: false, owned: &owned)
      return try disk.read(c, count: Int(length))
    }
    let bitmap = try metadata(bi)
    let upper = try caseMapping(metadata(ci), checksum: le(rootBytes, ci + 4, 4))
    var nodes = [
      ExFatNode(
        id: 1, name: "", size: rootBytes.count, directory: true, initialized: rootBytes.count,
        chain: rootChain)
    ]
    var children: [Component: UInt64] = [:]
    var order: [UInt64: [UInt64]] = [:]
    var cursor = 0
    var dirBudget = 16 << 20
    while cursor < nodes.count {
      let parent = nodes[cursor]
      cursor += 1
      guard parent.directory else { continue }
      guard parent.size <= dirBudget else { throw VolumeError.tooLarge }
      dirBudget -= parent.size
      let data = parent.id == 1 ? rootBytes : try disk.read(parent.chain, count: parent.size)
      var i = 0
      var label = false
      while i < data.count {
        let t = data[i]
        i += 32
        if t == 0 {
          for j in stride(from: i, to: data.count, by: 32) where data[j] != 0 {
            throw VolumeError.invalidMedia
          }
          break
        }
        if t & 128 == 0 { continue }
        let start = i - 32
        if parent.id == 1 {
          if t == 0x81 && start == bi || t == 0x82 && start == ci { continue }
          if t == 0x83 && !label && data[start + 1] <= 11 {
            label = true
            continue
          }
        }
        guard t == 0x85 else { throw VolumeError.invalidMedia }
        let secondary = Int(data[start + 1])
        let end = i + secondary * 32
        guard (2...18).contains(secondary), end <= data.count, data[i] == 0xc0 else {
          throw VolumeError.invalidMedia
        }
        var sum: UInt16 = 0
        for j in start..<end where j != start + 2 && j != start + 3 { sum = addByte(sum, data[j]) }
        let flags = data[i + 1]
        let length = Int(data[i + 3])
        let size = le(data, i + 24, 8)
        let valid = le(data, i + 8, 8)
        let first = Int(le(data, i + 20, 4))
        let dir = le(data, start + 4, 2) & 16 != 0
        guard le(data, start + 2, 2) == sum, flags == 1 || flags == 3,
          length > 0, secondary == 1 + (length + 14) / 15, valid <= size, size <= UInt64(Int.max),
          !dir
            || (size == valid && size % UInt64(disk.clusterBytes) == 0 && size <= UInt64(dirBudget))
        else { throw VolumeError.invalidMedia }
        var words: [UInt16] = []
        for f in stride(from: i + 32, to: end, by: 32) {
          guard data[f] == 0xc1, data[f + 1] == 0 else { throw VolumeError.invalidMedia }
          for j in 0..<15 {
            let word = UInt16(le(data, f + 2 + 2 * j, 2))
            if words.count < length {
              words.append(word)
            } else if word != 0 {
              throw VolumeError.invalidMedia
            }
          }
        }
        let display = try checkedName(words)
        let key = Component(parent: parent.id, upper: words.map { upper[Int($0)] })
        let hash = key.upper.reduce(UInt16(0)) {
          addByte(addByte($0, UInt8(truncatingIfNeeded: $1)), UInt8($1 >> 8))
        }
        guard hash == le(data, i + 4, 2), children[key] == nil else {
          throw VolumeError.invalidMedia
        }
        guard nodes.count < 65536 else { throw VolumeError.tooLarge }
        let chain = try disk.chain(
          first: first, length: size, contiguous: flags == 3, owned: &owned)
        let id = UInt64(nodes.count + 1)
        nodes.append(
          ExFatNode(
            id: id, name: display, size: Int(size), directory: dir, initialized: Int(valid),
            chain: chain))
        children[key] = id
        order[parent.id, default: []].append(id)
        i = end
      }
    }
    for c in owned {
      let bit = c - 2
      guard bitmap[bit / 8] & (1 << (bit % 8)) != 0 else { throw VolumeError.invalidMedia }
    }
    self.disk = disk
    self.upper = upper
    self.nodes = nodes
    self.children = children
    self.order = order
  }
  public func node(_ id: UInt64) throws -> ExFatNode {
    guard id > 0, id <= UInt64(nodes.count) else { throw VolumeError.notFound }
    return nodes[Int(id) - 1]
  }
  public func entry(parent: UInt64, index: UInt64) throws -> ExFatNode? {
    guard try node(parent).directory else { throw VolumeError.notDirectory }
    guard let ids = order[parent], index < UInt64(ids.count) else { return nil }
    return try node(ids[Int(index)])
  }
  public func lookup(parent: UInt64, name: [UInt8]) throws -> UInt64 {
    guard try node(parent).directory else { throw VolumeError.notDirectory }
    guard name.count <= 255, let s = String(validating: name, as: UTF8.self) else {
      throw VolumeError.invalidName
    }
    let words = Array(s.utf16)
    _ = try checkedName(words)
    guard let id = children[Component(parent: parent, upper: words.map { upper[Int($0)] })] else {
      throw VolumeError.notFound
    }
    return id
  }
  public func bytes(node id: UInt64, offset: UInt64, count: Int) throws -> [UInt8] {
    let file = try node(id)
    guard !file.directory else { throw VolumeError.isDirectory }
    guard (0...1 << 20).contains(count) else { throw VolumeError.tooLarge }
    guard offset < UInt64(file.size) else { return [] }
    let at = Int(offset)
    let n = min(count, file.size - at)
    let valid = min(n, max(0, file.initialized - at))
    return try disk.read(file.chain, offset: at, count: valid)
      + Array(repeating: 0, count: n - valid)
  }
}
