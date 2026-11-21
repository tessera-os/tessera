import KCore

/// Decode the physical handoff and cross-check the location of the block, map
/// and archive in it. The caller supplies stable mappings from an independent
/// authority. Never dereference a pointer obtained from the block to validate it.
/// Walk and validate firmware tables, event log, framebuffer and kernel separately.
@unsafe public func readHandoff(
  block: UnsafeRawBufferPointer, at address: UInt64,
  map: UnsafeRawBufferPointer, at mapAddress: UInt64
) -> BootInfo? {
  guard address != 0, block.count >= 4096, bootBlockFits(address, capacity: UInt64(block.count))
  else { return nil }
  var state = beginBootInfo(address, capacity: 4096)
  for i in 0..<4096 {
    guard acceptBootByte(&state, byte: block[i]) else { return nil }
  }
  guard let info = state.decoded, info.mapAddress == mapAddress,
    info.mapCount <= UInt64(map.count / 32),
    address + 4096 <= mapAddress || mapAddress + info.mapCount * 32 <= address
  else { return nil }
  var cursor = beginMemoryMap(info.mapCount, available: UInt64(map.count))
  var blockCovered = false
  var mapCovered = false
  var archiveCovered = false
  for i in 0..<Int(info.mapCount) {
    func word(_ offset: Int) -> UInt64 {
      UInt64(littleEndian: map.loadUnaligned(fromByteOffset: i * 32 + offset, as: UInt64.self))
    }
    let start = word(0)
    let length = word(8)
    let flags = word(16)
    guard
      acceptRegion(
        &cursor, base: start, length: length, typeAndAttributes: flags, reserved: word(24))
    else { return nil }
    func covers(_ base: UInt64, _ bytes: UInt64) -> Bool {
      base >= start && base - start <= length && bytes <= length - (base - start)
    }
    switch UInt32(truncatingIfNeeded: flags) {
    case 7: archiveCovered = archiveCovered || covers(info.bootSet, info.bootSetSize)
    case 8:
      blockCovered = blockCovered || covers(address, 4096)
      mapCovered = mapCovered || covers(mapAddress, info.mapCount * 32)
    default: break
    }
  }
  return completeMemoryMap(cursor) && blockCovered && mapCovered && archiveCovered ? info : nil
}
