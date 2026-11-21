/// An optional, rebuildable cache for page-in. Protect the root and layout
/// from writes; cached CVs are never a substitute for checking the frame.
public struct NativePageIndex {
  public let canonicalSize: UInt64
  public let root: BlakeCv
  private let unchangedPrefix: UInt64
  private let leaves: Int
  private let nodeCount: Int

  /// Number of initialized CV slots needed for an ELF in the TSG1 format.
  /// All levels, including promoted odd nodes and the root, are contiguous.
  public static func capacity(fileBytes: Int) -> Int? {
    guard fileBytes > 3373, fileBytes <= Int.max - 1024 else { return nil }
    var level = (fileBytes - 3374) / 1024 + 1
    var n = level
    while level > 1 {
      level = (level + 1) / 2
      n += level
    }
    return n
  }

  /// Supply the *same* immutable ELF and layout that passed signature and
  /// policy checks. Construction verifies its claimed digest, not its signer.
  /// Storage is caller-owned and disjoint from that ELF.
  public init?(
    file: UnsafeRawBufferPointer, image: InspectedImage,
    storage: UnsafeMutableBufferPointer<BlakeCv>
  ) {
    guard let n = Self.capacity(fileBytes: file.count), storage.count >= n,
      let id = image.notes.buildID, id.lowerBound >= 0, id.upperBound <= file.count, id.count == 32,
      let sig = image.notes.signature, let e = HybridEnvelope(file, descriptor: sig),
      !id.overlaps(sig)
    else { return nil }
    let view = DigestView(bytes: file, zeros: id, omit: e.ed25519.lowerBound..<e.mldsa65.upperBound)
    let size = UInt64(file.count - view.omit.count)
    let leafCount = Int((size - 1) / 1024) + 1
    for i in 0..<leafCount {
      guard let cv = view.leaf(i, size: size) else { return nil }
      storage[i] = cv
    }
    var base = 0
    var width = leafCount
    while width > 1 {
      let next = base + width
      for i in stride(from: 0, to: width, by: 2) {
        let left = storage[base + i]
        if i + 1 == width {
          storage[next + i / 2] = left
        } else {
          let pair = BlakeBlock(low: left, high: storage[base + i + 1])
          storage[next + i / 2] = blakeCompress(initialCv(), pair, 0, 64, width == 2 ? 12 : 4)
        }
      }
      base = next
      width = (width + 1) / 2
    }
    let identity = DigestView(bytes: file, zeros: 0..<0, omit: 0..<0).cv(
      id.lowerBound, id.upperBound)
    guard storage[base].matches(identity) else { return nil }
    self.canonicalSize = size
    self.root = identity
    self.unchangedPrefix = UInt64(min(id.lowerBound, sig.lowerBound))
    self.leaves = leafCount
    self.nodeCount = n
  }

  /// Emit sibling CVs in verifyFilePage order. Only complete, unchanged
  /// file pages before the notes qualify; segment permissions, offset and
  /// zero-fill of segment padding are separate checks by the fault path.
  public func witnesses(
    offset: UInt64, pageSize: UInt64, nodes: UnsafeBufferPointer<BlakeCv>,
    into output: UnsafeMutableRawBufferPointer
  ) -> Int? {
    guard nodes.count >= nodeCount, pageSize == 4096 || pageSize == 16384,
      offset % pageSize == 0, imageContains(unchangedPrefix, offset, pageSize)
    else { return nil }
    var used = 0
    let first = Int(offset / 1024)
    for leaf in first..<first + Int(pageSize / 1024) {
      var at = leaf
      var width = leaves
      var base = 0
      while width > 1 {
        let sibling = at ^ 1
        if sibling < width {
          guard output.count - used >= 32 else { return nil }
          let cv = nodes[base + sibling]
          output.storeBytes(of: cv.w0.littleEndian, toByteOffset: used, as: UInt32.self)
          output.storeBytes(of: cv.w1.littleEndian, toByteOffset: used + 4, as: UInt32.self)
          output.storeBytes(of: cv.w2.littleEndian, toByteOffset: used + 8, as: UInt32.self)
          output.storeBytes(of: cv.w3.littleEndian, toByteOffset: used + 12, as: UInt32.self)
          output.storeBytes(of: cv.w4.littleEndian, toByteOffset: used + 16, as: UInt32.self)
          output.storeBytes(of: cv.w5.littleEndian, toByteOffset: used + 20, as: UInt32.self)
          output.storeBytes(of: cv.w6.littleEndian, toByteOffset: used + 24, as: UInt32.self)
          output.storeBytes(of: cv.w7.littleEndian, toByteOffset: used + 28, as: UInt32.self)
          used += 32
        }
        base += width
        width = (width + 1) / 2
        at /= 2
      }
    }
    return used
  }
}
