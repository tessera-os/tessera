import TarwinReadOnlyFS

func le(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
  var x: UInt64 = 0
  for i in 0..<n { x |= UInt64(b[at + i]) << (8 * i) }
  return x
}

func addByte<T: FixedWidthInteger & UnsignedInteger>(_ sum: T, _ byte: UInt8) -> T {
  ((sum >> 1) | (sum << (T.bitWidth - 1))) &+ T(byte)
}

private func exact<M: VolumeMedia>(_ media: M, _ offset: UInt64, _ n: Int) throws -> [UInt8] {
  guard n >= 0, offset <= media.byteCount, UInt64(n) <= media.byteCount - offset,
    let b = media.read(at: offset, count: n), b.count == n
  else { throw VolumeError.io }
  return b
}

struct ExDisk<M: VolumeMedia> {
  let media: M, clusterBytes: Int, clusters: Int, root: Int
  private let heap: UInt64, fat: [UInt8]
  init(_ media: M) throws {
    let prefix = try exact(media, 0, 512)
    guard (9...12).contains(prefix[108]) else { throw VolumeError.invalidMedia }
    let sector = 1 << Int(prefix[108])
    let main = try exact(media, 0, 12 * sector)
    let backup = try exact(media, UInt64(12 * sector), 12 * sector)
    for region in [main, backup] {
      guard region.prefix(3).elementsEqual([0xeb, 0x76, 0x90]),
        region[3..<11].elementsEqual("EXFAT   ".utf8), region[11..<64].allSatisfy({ $0 == 0 }),
        le(region, 104, 2) == 256, region[110] == 1, le(region, 510, 2) == 0xaa55
      else { throw VolumeError.invalidMedia }
      for i in 2...9 where le(region, i * sector - 4, 4) != 0xaa55_0000 {
        throw VolumeError.invalidMedia
      }
      var sum: UInt32 = 0
      for i in 0..<11 * sector where i != 106 && i != 107 && i != 112 {
        sum = addByte(sum, region[i])
      }
      for i in stride(from: 11 * sector, to: 12 * sector, by: 4) where le(region, i, 4) != sum {
        throw VolumeError.invalidMedia
      }
    }
    guard main[64..<106].elementsEqual(backup[64..<106]),
      main[108..<112].elementsEqual(backup[108..<112]),
      main[108] == prefix[108], le(main, 106, 2) & ~8 == 0, main[112] <= 100 || main[112] == 255,
      Int(main[108]) + Int(main[109]) <= 20
    else { throw VolumeError.invalidMedia }
    let spc: UInt64 = 1 << main[109]
    let volume = le(main, 72, 8)
    let fatStart = le(main, 80, 4)
    let fatSize = le(main, 84, 4)
    let heapStart = le(main, 88, 4)
    let count = le(main, 92, 4)
    let root = le(main, 96, 4)
    guard volume >= UInt64((1 << 20) / sector), volume <= media.byteCount / UInt64(sector),
      fatStart >= 24, heapStart >= fatStart + fatSize, heapStart < volume,
      count > 0, count <= 1 << 20, count == (volume - heapStart) / spc,
      (count + 2) * 4 <= fatSize * UInt64(sector), root >= 2, root <= count + 1
    else { throw VolumeError.invalidMedia }
    self.media = media
    self.root = Int(root)
    clusters = Int(count)
    clusterBytes = Int(spc) * sector
    heap = heapStart * UInt64(sector)
    fat = try exact(media, fatStart * UInt64(sector), Int(count + 2) * 4)
    guard le(fat, 0, 4) >> 8 == 0xffffff, le(fat, 4, 4) == 0xffff_ffff else {
      throw VolumeError.invalidMedia
    }
  }

  // One mount-wide ownership set prevents cycles, cross-links and data
  // streams from aliasing directory, bitmap or up-case table storage.
  func chain(first: Int, length: UInt64?, contiguous: Bool, owned: inout Set<Int>) throws -> [Int] {
    if length == 0 {
      guard first == 0, !contiguous else { throw VolumeError.invalidMedia }
      return []
    }
    let width = UInt64(clusterBytes)
    let needed = length.map { 1 + ($0 - 1) / width }
    guard needed ?? 0 <= UInt64(clusters) else { throw VolumeError.invalidMedia }
    var current = first
    var out: [Int] = []
    while true {
      guard current >= 2, current < clusters + 2, owned.insert(current).inserted else {
        throw VolumeError.invalidMedia
      }
      out.append(current)
      if length == nil && out.count * clusterBytes > 16 << 20 { throw VolumeError.tooLarge }
      if contiguous && UInt64(out.count) == needed { break }
      let next = contiguous ? current + 1 : Int(le(fat, current * 4, 4))
      if next == 0xffff_ffff { break }
      guard needed.map({ UInt64(out.count) < $0 }) ?? true else { throw VolumeError.invalidMedia }
      current = next
    }
    guard needed.map({ $0 == UInt64(out.count) }) ?? true else { throw VolumeError.invalidMedia }
    return out
  }
  func read(_ chain: [Int], offset: Int = 0, count: Int) throws -> [UInt8] {
    var out: [UInt8] = []
    var pos = offset
    out.reserveCapacity(count)
    while out.count < count {
      let slot = pos / clusterBytes
      let within = pos % clusterBytes
      let n = min(count - out.count, clusterBytes - within)
      guard slot < chain.count else { throw VolumeError.invalidMedia }
      let at = heap + UInt64(chain[slot] - 2) * UInt64(clusterBytes) + UInt64(within)
      out += try exact(media, at, n)
      pos += n
    }
    return out
  }
}

func caseMapping(_ data: [UInt8], checksum: UInt64) throws -> [UInt16] {
  guard !data.isEmpty, data.count <= 131072, data.count % 2 == 0,
    data.reduce(UInt32(0), addByte) == checksum
  else { throw VolumeError.invalidMedia }
  var words: [UInt16] = []
  var i = 0
  words.reserveCapacity(65536)
  while i < data.count {
    let v = UInt16(le(data, i, 2))
    i += 2
    guard words.count < 65536 else { throw VolumeError.invalidMedia }
    if v == .max && words.count != 65535 && data.count != 131072 {
      guard i < data.count else { throw VolumeError.invalidMedia }
      let n = Int(le(data, i, 2))
      i += 2
      guard n > 0, n <= 65536 - words.count else { throw VolumeError.invalidMedia }
      for j in words.count..<(words.count + n) { words.append(UInt16(j)) }
    } else {
      words.append(v)
    }
  }
  guard words.count == 65536 else { throw VolumeError.invalidMedia }
  for c in 0..<128 where words[c] != UInt16((97...122).contains(c) ? c - 32 : c) {
    throw VolumeError.invalidMedia
  }
  return words
}
