import TarwinReadOnlyFS

public typealias FatMedia = VolumeMedia
public typealias FatError = VolumeError
public typealias FatStep = ReadOnlyStep
public typealias FatShares = ReadOnlyShares
public typealias FatServer<M: FatMedia> = ReadOnlyServer<FatVolume<M>>

public struct FatNode: ReadOnlyNode {
  public let id: UInt64, name: String, size: Int, directory: Bool
  fileprivate let chain: [Int]
}
private func word(_ b: [UInt8], _ p: Int, _ n: Int) -> Int {
  var v = 0
  for i in 0..<n { v |= Int(b[p + i]) << (8 * i) }
  return v
}
private func read<M: FatMedia>(_ media: M, _ offset: Int, _ bytes: Int) throws -> [UInt8] {
  guard offset >= 0, bytes >= 0, UInt64(offset) <= media.byteCount,
    UInt64(bytes) <= media.byteCount - UInt64(offset),
    let b = media.read(at: UInt64(offset), count: bytes), b.count == bytes
  else { throw FatError.io }
  return b
}
private func legal(_ c: UInt8) -> Bool {
  c >= 33 && c <= 126 && !"\"*+,./:;<=>?[\\]|".utf8.contains(c)
}
private func canonical(_ bytes: [UInt8]) throws -> String {
  guard (1...12).contains(bytes.count) else { throw FatError.invalidName }
  let parts = bytes.split(separator: 46, omittingEmptySubsequences: false)
  guard parts.count <= 2, (1...8).contains(parts[0].count),
    parts.count == 1 || (1...3).contains(parts[1].count),
    parts.allSatisfy({ $0.allSatisfy(legal) })
  else { throw FatError.invalidName }
  return String(decoding: bytes.map { (97...122).contains($0) ? $0 - 32 : $0 }, as: UTF8.self)
}

/// FAT16 and FAT32 with ASCII short filenames; metadata is verified before exposing
/// the root. Directory indices contain only discovered nodes, not raw sectors.
public struct FatVolume<M: FatMedia>: ReadOnlyVolume {
  public static var maxNameBytes: UInt32 { 12 }
  public let root: UInt64 = 1
  private let media: M, clusterBytes: Int, dataStart: Int, nodes: [FatNode],
    children: [UInt64: [String: UInt64]]
  private let order: [UInt64: [UInt64]]
  public init(_ media: M) throws {
    let b = try read(media, 0, 512)
    let sector = word(b, 11, 2)
    let spc = Int(b[13])
    let reserved = word(b, 14, 2)
    let copies = Int(b[16])
    let entries = word(b, 17, 2)
    let small = word(b, 19, 2)
    let large = word(b, 32, 4)
    let fat16Sectors = word(b, 22, 2)
    let fatSectors = fat16Sectors == 0 ? word(b, 36, 4) : fat16Sectors
    guard b[510] == 0x55, b[511] == 0xaa, [512, 1024, 2048, 4096].contains(sector),
      spc > 0, spc.nonzeroBitCount == 1, sector * spc <= 32768, reserved > 0,
      (1...2).contains(copies),
      fatSectors > 0, (small == 0) != (large == 0)
    else { throw FatError.invalidMedia }
    let total = max(small, large)
    let rootSector = reserved + copies * fatSectors
    let first = rootSector + (entries * 32 + sector - 1) / sector
    guard first < total, UInt64(total * sector) <= media.byteCount else {
      throw FatError.invalidMedia
    }
    let clusters = (total - first) / spc
    let cb = spc * sector
    let data = first * sector
    let wide = clusters >= 65525
    let width = wide ? 4 : 2
    guard clusters <= 1_048_576 else { throw FatError.tooLarge }
    guard (clusters + 2) * width <= fatSectors * sector else {
      throw FatError.invalidMedia
    }
    let flags = wide ? word(b, 40, 2) : 0
    let mirrored = flags & 0x80 == 0
    let active = mirrored ? 0 : flags & 15
    if wide {
      guard entries == 0, small == 0, fat16Sectors == 0, word(b, 42, 2) == 0,
        flags & 0xff70 == 0, active < copies
      else { throw FatError.invalidMedia }
    } else if !(4085...65518).contains(clusters) || entries == 0 || fat16Sectors == 0 {
      throw FatError.invalidMedia
    }
    let mask = wide ? 0x0fff_ffff : 0xffff
    let fat = try read(media, (reserved + active * fatSectors) * sector, (clusters + 2) * width)
    func entry(_ id: Int) -> Int { word(fat, id * width, width) & mask }
    guard entry(0) == (mask & ~255) | Int(b[21]), entry(1) == mask else {
      throw FatError.invalidMedia
    }
    if mirrored && copies == 2 {
      let mirror = try read(media, (reserved + fatSectors) * sector, fat.count)
      for i in 0..<(clusters + 2) where entry(i) != word(mirror, i * width, width) & mask {
        throw FatError.invalidMedia
      }
    }
    var claimed = [Bool](repeating: false, count: clusters + 2)
    func chain(_ first: Int) throws -> [Int] {
      var ids: [Int] = []
      var id = first
      while true {
        guard id >= 2, id < claimed.count, !claimed[id] else { throw FatError.invalidMedia }
        claimed[id] = true
        ids.append(id)
        id = entry(id)
        if id >= mask - 7 { return ids }
      }
    }
    var index = [
      FatNode(
        id: 1, name: "", size: 0, directory: true,
        chain: wide ? try chain(word(b, 44, 4)) : [])
    ]
    var byParent: [UInt64: [String: UInt64]] = [:]
    var order: [UInt64: [UInt64]] = [:]
    var scanned = 0
    func scan(_ directory: FatNode, _ bytes: [UInt8]) throws -> Bool {
      for p in stride(from: 0, to: bytes.count, by: 32) {
        scanned += 1
        guard scanned <= 1_048_576 else { throw FatError.tooLarge }
        if bytes[p] == 0 { return false }
        let attr = bytes[p + 11]
        if bytes[p] == 0xe5 || attr == 0x0f || attr & 8 != 0 { continue }
        func part(_ start: Int, _ len: Int) -> [UInt8] {
          var end = start + len
          while end > start && bytes[p + end - 1] == 32 { end -= 1 }
          return Array(bytes[(p + start)..<(p + end)])
        }
        let base = part(0, 8)
        let ext = part(8, 3)
        if ext.isEmpty && (base == [46] || base == [46, 46]) { continue }
        let name = try canonical(base + (ext.isEmpty ? [] : [46] + ext))
        let isDir = attr & 16 != 0
        let size = word(bytes, p + 28, 4)
        let hi = word(bytes, p + 20, 2)
        let cluster = (hi << 16) | word(bytes, p + 26, 2)
        guard attr & 0xc0 == 0, wide || hi == 0, index.count < 65536,
          byParent[directory.id]?[name] == nil,
          !isDir || size == 0
        else { throw FatError.invalidMedia }
        let ids = cluster == 0 ? [] : try chain(cluster)
        guard isDir ? !ids.isEmpty : ids.count == (size + cb - 1) / cb else {
          throw FatError.invalidMedia
        }
        let id = UInt64(index.count + 1)
        order[directory.id, default: []].append(id)
        byParent[directory.id, default: [:]][name] = id
        index.append(FatNode(id: id, name: name, size: size, directory: isDir, chain: ids))
      }
      return true
    }
    if !wide { _ = try scan(index[0], read(media, rootSector * sector, entries * 32)) }
    var i = wide ? 0 : 1
    while i < index.count {
      let node = index[i]
      i += 1
      if node.directory {
        for c in node.chain {
          if try !scan(node, read(media, data + (c - 2) * cb, cb)) { break }
        }
      }
    }
    self.media = media
    self.clusterBytes = cb
    self.dataStart = data
    self.nodes = index
    self.children = byParent
    self.order = order
  }
  public func node(_ id: UInt64) throws -> FatNode {
    guard id > 0, id <= UInt64(nodes.count) else { throw FatError.notFound }
    return nodes[Int(id) - 1]
  }
  public func lookup(parent: UInt64, name: [UInt8]) throws -> UInt64 {
    guard try node(parent).directory else { throw FatError.notDirectory }
    let key = try canonical(name)
    guard let id = children[parent]?[key] else { throw FatError.notFound }
    return id
  }
  public func entry(parent: UInt64, index: UInt64) throws -> FatNode? {
    guard try node(parent).directory else { throw FatError.notDirectory }
    guard let ids = order[parent], index < UInt64(ids.count) else { return nil }
    return try node(ids[Int(index)])
  }
  public func bytes(node id: UInt64, offset: UInt64, count: Int) throws -> [UInt8] {
    let file = try node(id)
    guard !file.directory else { throw FatError.isDirectory }
    guard count >= 0, count <= 1 << 20 else { throw FatError.tooLarge }
    guard offset < file.size else { return [] }
    var at = Int(offset)
    var left = min(count, file.size - at)
    var out: [UInt8] = []
    out.reserveCapacity(left)
    while left > 0 {
      let within = at % clusterBytes
      let n = min(clusterBytes - within, left)
      let base = dataStart + (file.chain[at / clusterBytes] - 2) * clusterBytes
      out += try read(media, base + within, n)
      at += n
      left -= n
    }
    return out
  }
}
