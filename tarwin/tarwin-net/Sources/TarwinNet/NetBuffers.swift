/// A kernel snapshot of already pinned writable spans, not user descriptors.
struct NetScatter {
  let capacity: Int
  private let buffers: [UnsafeMutableRawBufferPointer]
  private var index = 0, offset = 0
  init?(_ buffers: [UnsafeMutableRawBufferPointer], limit: Int) {
    guard !buffers.isEmpty, buffers.count <= limit else { return nil }
    var capacity = 0
    for b in buffers {
      guard b.count <= Int.max - capacity, b.isEmpty || b.baseAddress != nil else { return nil }
      capacity += b.count
    }
    self.buffers = buffers
    self.capacity = capacity
  }
  mutating func copy(_ bytes: ArraySlice<UInt8>) {
    bytes.withUnsafeBytes { source in
      var i = 0
      while i < source.count {
        while index < buffers.count && offset == buffers[index].count {
          index += 1
          offset = 0
        }
        precondition(index < buffers.count)
        let b = buffers[index]
        let n = min(source.count - i, b.count - offset)
        b.baseAddress!.advanced(by: offset).copyMemory(
          from: source.baseAddress!.advanced(by: i), byteCount: n)
        i += n
        offset += n
      }
    }
  }
}

/// LibTessera §15.2: store scalar fields little-endian and address octets in network order.
func storePeer(
  _ address: [UInt8], port: UInt16, interface: UInt32, to b: UnsafeMutableRawBufferPointer
) {
  precondition(b.count == 32 && (address.count == 4 || address.count == 16))
  for i in 0..<32 { b[i] = 0 }
  b[0] = address.count == 4 ? 0 : 1
  b[4] = UInt8(truncatingIfNeeded: port)
  b[5] = UInt8(port >> 8)
  for i in address.indices { b[8 + i] = address[i] }
  if address.count == 16, address[0] == 0xfe, address[1] & 0xc0 == 0x80 {
    b[6] = 1
    for i in 0..<4 { b[24 + i] = UInt8(truncatingIfNeeded: interface >> (8 * i)) }
  }
}
