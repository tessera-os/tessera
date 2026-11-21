extension HostedFileBacking {
  public typealias ReadTrfsBlock = (
    _ block: UInt64, _ buffer: UnsafeMutableRawBufferPointer
  ) throws -> Int

  public static func trfsSnapshot(
    size: UInt64, readBlock: @escaping ReadTrfsBlock
  ) -> HostedFileBacking {
    let blockSize = 4096
    return HostedFileBacking(size: size) { offset, page in
      let valid = Int(min(UInt64(page.count), size - offset))
      for start in stride(from: 0, to: valid, by: blockSize) {
        let buffer = UnsafeMutableRawBufferPointer(rebasing: page[start..<(start + blockSize)])
        let block = (offset + UInt64(start)) / UInt64(blockSize)
        guard try readBlock(block, buffer) == min(blockSize, valid - start) else {
          throw HostedFaultError.incompleteRead
        }
      }
      return valid
    }
  }
}
