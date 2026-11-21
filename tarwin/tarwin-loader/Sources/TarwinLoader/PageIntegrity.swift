// One inclusion proof for a chunk in the exact byte stream covered by the
// signed build ID. Tree shape and direction come from the signed size and
// the requested chunk's index, never from proof metadata.
public struct ImageChunkProof {
  public let size: UInt64
  public let chunk: UInt64
  public internal(set) var remaining: UInt64
  public internal(set) var position: UInt64
  public internal(set) var nodes: UInt64
  public internal(set) var first: Bool
  public internal(set) var hashed: Bool
  public internal(set) var failed: Bool
  public internal(set) var chain: BlakeCv

  // Each block is 16 little-endian words, zero-padded beyond its length.
  public mutating func absorb(_ block: BlakeBlock, _ length: UInt32) -> Bool {
    var expected = remaining
    if expected > 64 { expected = 64 }
    if failed || hashed || UInt64(length) != expected {
      failed = true
      return false
    }
    var flags: UInt32 = 0
    if first { flags = 1 }
    if remaining == expected {
      flags = flags | 2
      hashed = true
      if nodes == 1 { flags = flags | 8 }
    }
    chain = blakeCompress(chain, block, chunk, length, flags)
    first = false
    remaining -= expected
    return true
  }

  // Unpaired rightmost nodes rise unchanged; no proof word is consumed
  // for them. Input siblings are ordered leaf to root.
  public mutating func sibling(_ other: BlakeCv) -> Bool {
    if failed || !hashed || nodes <= 1 {
      failed = true
      return false
    }
    while (nodes & 1) != 0 && position == nodes - 1 {
      position = position >> 1
      nodes = (nodes + 1) >> 1
    }
    var pair = BlakeBlock(low: chain, high: other)
    if (position & 1) != 0 { pair = BlakeBlock(low: other, high: chain) }
    var flags: UInt32 = 4
    if nodes == 2 { flags = 12 }
    chain = blakeCompress(initialCv(), pair, 0, 64, flags)
    position = position >> 1
    nodes = (nodes + 1) >> 1
    return true
  }

  public func verifies(_ signedRoot: BlakeCv) -> Bool {
    return !failed && hashed && nodes == 1 && position == 0
      && chain.matches(
        signedRoot
      )
  }
}

// Interior non-root node used to build the loader's proof cache.
public func imageParentCv(_ left: BlakeCv, _ right: BlakeCv) -> BlakeCv {
  let block = BlakeBlock(low: left, high: right)
  return blakeCompress(initialCv(), block, 0, 64, 4)
}

public func imageChunk(_ size: UInt64, _ chunk: UInt64) -> ImageChunkProof {
  var nodes: UInt64 = 1
  if size != 0 { nodes = (size - 1) / 1024 + 1 }
  var length: UInt64 = 0
  if chunk < nodes {
    length = size - chunk * 1024
    if length > 1024 { length = 1024 }
  }
  return ImageChunkProof(
    size: size,
    chunk: chunk,
    remaining: length,
    position: chunk,
    nodes: nodes,
    first: true,
    hashed: false,
    failed: chunk >= nodes,
    chain: initialCv())
}

// The pager keeps the source page private and pinned until this verifies.
// Zero-fill any tail after EOF; this covers only the file-backed bytes. It
// neither validates an image signature nor grants executable permission.
public struct PageIntegrity {
  public let size: UInt64
  public let endChunk: UInt64
  public let root: BlakeCv
  public internal(set) var nextChunk: UInt64
  public internal(set) var failed: Bool

  public mutating func accept(_ proof: ImageChunkProof) -> Bool {
    if failed || nextChunk >= endChunk || size != proof.size || nextChunk != proof.chunk
      || !proof.verifies(root)
    {
      failed = true
      return false
    }
    nextChunk += 1
    return true
  }

  public func verified() -> Bool { return !failed && nextChunk == endChunk }
}

public func pageIntegrity(
  _ size: UInt64,
  _ offset: UInt64,
  _ pageBytes: UInt64,
  _ root: BlakeCv
) -> PageIntegrity {
  let first = offset / 1024
  var count: UInt64 = 0
  if (pageBytes == 4096 || pageBytes == 16384) && offset < size && offset % pageBytes == 0 {
    var length = size - offset
    if length > pageBytes { length = pageBytes }
    count = (length - 1) / 1024 + 1
  }
  return PageIntegrity(
    size: size,
    endChunk: first + count,
    root: root,
    nextChunk: first,
    failed: count == 0)
}
