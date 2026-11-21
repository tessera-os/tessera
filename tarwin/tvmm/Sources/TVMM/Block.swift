public enum BlockOperation { case read, write, flush, discard, writeZeroes }
public enum BlockError: Error { case io, unsupported }
public struct BlockRequest {
  public let operation: BlockOperation
  public let byteOffset: UInt64
  public let byteLength: UInt64

  public init(operation: BlockOperation, byteOffset: UInt64, byteLength: UInt64) {
    self.operation = operation
    self.byteOffset = byteOffset
    self.byteLength = byteLength
  }
}
public struct BlockRange {
  public let offset: UInt64
  public let length: UInt64
  public let unmap: Bool

  public init(offset: UInt64, length: UInt64, unmap: Bool) {
    self.offset = offset
    self.length = length
    self.unmap = unmap
  }
}

func rangeFits(_ sector: UInt64, _ size: UInt64, _ capacity: UInt64) -> Bool {
  return size % 512 == 0 && sector <= capacity && size / 512 <= capacity - sector
    && sector <= 0xffff_ffff_ffff_ffff / 512
    && size <= 0xffff_ffff_ffff_ffff - sector * 512
}

// Decode the readable header separately from the writable status byte. The caller
// assembles the bytes from validated scatter/gather segments, not from host pointers.
public func blockRequest(
  _ header: [UInt8], _ readableData: UInt64, _ writableData: UInt64,
  _ capacitySectors: UInt64, _ readOnly: Bool, _ canFlush: Bool,
  _ canDiscard: Bool, _ canZero: Bool
) -> Result<BlockRequest, BlockError> {
  if header.count != 16 { return .failure(.io) }
  let op = vword(header, 0, 4)
  let sector = vword(header, 8, 8)
  switch op {
  case 0, 1:
    let write = op == 1
    if (write && (readOnly || writableData != 0)) || (!write && readableData != 0) {
      return .failure(.io)
    }
    let size = write ? readableData : writableData
    if !rangeFits(sector, size, capacitySectors) { return .failure(.io) }
    return .success(
      BlockRequest(operation: write ? .write : .read, byteOffset: sector * 512, byteLength: size))

  case 4:
    if !canFlush { return .failure(.unsupported) }
    if readableData != 0 || writableData != 0 || sector != 0 { return .failure(.io) }
    return .success(BlockRequest(operation: .flush, byteOffset: 0, byteLength: 0))

  case 11, 13:
    if (op == 11 && !canDiscard) || (op == 13 && !canZero) { return .failure(.unsupported) }
    if readOnly || writableData != 0 || readableData == 0 || readableData % 16 != 0 {
      return .failure(.io)
    }
    return .success(
      BlockRequest(
        operation: op == 11 ? .discard : .writeZeroes, byteOffset: 0, byteLength: readableData))

  default: return .failure(.unsupported)
  }
}

public func blockRanges(
  _ payload: [UInt8], _ operation: BlockOperation, _ maxRanges: UInt64,
  _ maxSectors: UInt64, _ capacity: UInt64, _ mayUnmap: Bool
) -> Result<[BlockRange], BlockError> {
  if operation != .discard && operation != .writeZeroes { return .failure(.unsupported) }
  if payload.count < 16 || payload.count % 16 != 0 || UInt64(payload.count / 16) > maxRanges {
    return .failure(.io)
  }
  var ranges: [BlockRange] = []
  for i in 0..<(payload.count / 16) {
    let sector = vword(payload, i * 16, 8)
    let sectors = vword(payload, i * 16 + 8, 4)
    let flags = vword(payload, i * 16 + 12, 4)
    if flags != 0 && !(flags == 1 && operation == .writeZeroes && mayUnmap) {
      return .failure(.unsupported)
    }
    let size = sectors * 512
    if sectors > maxSectors || !rangeFits(sector, size, capacity) { return .failure(.io) }
    ranges.append(BlockRange(offset: sector * 512, length: size, unmap: flags == 1))
  }
  return .success(ranges)
}
