// Private bytes from the guest-readable spans; 'space' counts pinned guest-writable
// bytes. No handler dereferences a descriptor address. A result is copied only to the
// writable spans, in order; None means the descriptor cannot receive a valid reply.
public enum DeviceIoLimit { public static let bytes: UInt64 = 1_048_576 }

public func gatherDeviceRequest(_ segments: [Segment], _ readByte: (UInt64) -> UInt8) -> [UInt8]? {
  var total: UInt64 = 0
  for s in segments {
    if !s.writable {
      if s.length > DeviceIoLimit.bytes - total { return .none }
      total += s.length
    }
  }
  var bytes: [UInt8] = []
  for s in segments {
    if !s.writable { for n in 0..<Int(s.length) { bytes.append(readByte(s.address + UInt64(n))) } }
  }
  return .some(bytes)
}

public func scatterDeviceReply(
  _ segments: [Segment], _ bytes: [UInt8],
  _ writeByte: (UInt64, UInt8) -> Void
) -> Bool {
  if UInt64(bytes.count) > DeviceIoLimit.bytes { return false }
  var left = UInt64(bytes.count)
  for s in segments { if s.writable { left -= left < s.length ? left : s.length } }
  if left != 0 { return false }
  var done = 0
  for s in segments {
    if !s.writable || done == bytes.count { continue }
    let take = s.length < UInt64(bytes.count - done) ? Int(s.length) : bytes.count - done
    for n in 0..<take { writeByte(s.address + UInt64(n), bytes[done + n]) }
    done += take
  }
  return true
}

public struct BlockFeatures {
  public let capacity: UInt64
  public let readOnly: Bool
  public let flush: Bool
  public let discard: Bool
  public let zero: Bool
  public let maxRanges: UInt64
  public let maxSectors: UInt64
  public let unmapZeroes: Bool

  public init(
    capacity: UInt64, readOnly: Bool, flush: Bool, discard: Bool, zero: Bool, maxRanges: UInt64,
    maxSectors: UInt64, unmapZeroes: Bool
  ) {
    self.capacity = capacity
    self.readOnly = readOnly
    self.flush = flush
    self.discard = discard
    self.zero = zero
    self.maxRanges = maxRanges
    self.maxSectors = maxSectors
    self.unmapZeroes = unmapZeroes
  }
}

// The status byte is always LAST in the writable stream, even for a failed read.
// Buffer whole reads before publication; zero-fill rather than leaking host bytes on error.
func blockStatus(_ space: UInt64, _ status: UInt8) -> [UInt8] {
  var result: [UInt8] = []
  for _ in 1..<Int(space) { result.append(0) }
  result.append(status)
  return result
}

public func executeBlock(
  _ command: [UInt8], _ space: UInt64, _ config: BlockFeatures,
  _ readImage: (UInt64, UInt64) -> [UInt8], _ writeImage: (UInt64, [UInt8]) -> Bool,
  _ syncImage: () -> Bool, _ applyRange: (BlockOperation, BlockRange) -> Bool
) -> [UInt8]? {
  if space == 0 || space > DeviceIoLimit.bytes { return .none }
  if command.count < 16 || UInt64(command.count) > DeviceIoLimit.bytes {
    return .some(blockStatus(space, 1))
  }
  var header: [UInt8] = []
  for i in 0..<16 { header.append(command[i]) }
  let request: BlockRequest
  switch blockRequest(
    header, UInt64(command.count - 16), space - 1, config.capacity,
    config.readOnly, config.flush, config.discard, config.zero)
  {
  case .failure(let e):
    let status: UInt8 = e == BlockError.unsupported ? 2 : 1
    return .some(blockStatus(space, status))

  case .success(let r): request = r
  }
  if request.operation == .read {
    var bytes = readImage(request.byteOffset, request.byteLength)
    if UInt64(bytes.count) != request.byteLength { return .some(blockStatus(space, 1)) }
    bytes.append(0)
    return .some(bytes)
  }
  if request.operation == .flush { return .some(blockStatus(space, syncImage() ? 0 : 1)) }
  var data: [UInt8] = []
  for i in 16..<command.count { data.append(command[i]) }
  if request.operation == .write {
    return .some(blockStatus(space, writeImage(request.byteOffset, data) ? 0 : 1))
  }
  let ranges: [BlockRange]
  switch blockRanges(
    data, request.operation, config.maxRanges, config.maxSectors,
    config.capacity, config.unmapZeroes)
  {
  case .success(let r): ranges = r
  case .failure(let e):
    let status: UInt8 = e == BlockError.unsupported ? 2 : 1
    return .some(blockStatus(space, status))
  }
  for r in ranges {
    if !applyRange(request.operation, r) { return .some(blockStatus(space, 1)) }
  }
  return .some(blockStatus(space, 0))
}

public func rngReceive(_ space: UInt64, _ quota: UInt64, _ secureBytes: (UInt64) -> [UInt8])
  -> [UInt8]?
{
  let allowed = space < quota ? space : quota
  let n = allowed < DeviceIoLimit.bytes ? allowed : DeviceIoLimit.bytes
  if n == 0 { return .none }
  let bytes = secureBytes(n)
  if bytes.count == 0 || UInt64(bytes.count) > n { return .none }
  return .some(bytes)
}

public func pmemFlush(_ command: [UInt8], _ space: UInt64, _ persistRange: () -> Bool) -> [UInt8]? {
  if space < 4 || command.count != 4 { return .none }
  let ok = vword(command, 0, 4) == 0 && persistRange()
  let status: UInt8 = ok ? 0 : 255
  return .some([status, status, status, status])
}

public func inputEvent(_ typeCode: UInt64, _ code: UInt64, _ valueBits: UInt64) -> [UInt8]? {
  if typeCode > 65535 || code > 65535 || valueBits > 0xffff_ffff { return .none }
  var event: [UInt8] = [
    UInt8(typeCode & 255), UInt8(typeCode >> 8), UInt8(code & 255), UInt8(code >> 8),
  ]
  for n in 0..<4 { event.append(UInt8((valueBits >> UInt64(n * 8)) & 255)) }
  return .some(event)
}
