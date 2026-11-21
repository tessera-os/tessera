import KCore
import TarwinBoot

struct LoaderExtent {
  let base: UInt64
  let length: UInt64
  let kind: UInt32

  var valid: Bool {
    base > 0 && (base | length) & 4095 == 0 && validExtent(base, length: length)
  }
}

// Only exact, held EFI reservations become typed boot information or boot-set
// entries. Adjacent, unrelated LoaderData pages never inherit either type.
func writeHandoffMap(
  _ regions: UnsafeBufferPointer<FirmwareRegion>, archive: LoaderExtent,
  handoff: LoaderExtent, into output: UnsafeMutableRawBufferPointer
) -> Int? {
  guard archive.valid, handoff.valid, archive.kind == 7, handoff.kind == 8 else { return nil }
  let first = archive.base < handoff.base ? archive : handoff
  let second = archive.base < handoff.base ? handoff : archive
  guard first.base + first.length <= second.base else { return nil }
  var pins = 0
  var count = 0
  var last: UInt64 = 0
  func emit(_ start: UInt64, _ end: UInt64, _ kind: UInt32, _ attributes: UInt64, _ count: inout Int) -> Bool {
    if start == end { return true }
    guard count < output.count / 32 else { return false }
    let entry = PhysicalRegion(
      base: start, length: end - start, kind: kind,
      attributes: UInt32(truncatingIfNeeded: attributes))
    for i in 0..<32 { output[count * 32 + i] = regionByte(entry, offset: UInt64(i)) }
    count += 1
    return true
  }
  for r in regions {
    guard validExtent(r.base, length: r.length), last <= r.base else { return nil }
    let end = r.base + r.length
    last = end
    var start = r.base
    // Do not release firmware boot services, stack, FDT or loader storage
    // while they are still being used in the handoff identity mapping.
    let kind = r.bootMapKind(afterExit: false)
    while pins < 2 {
      let pin = pins == 0 ? first : second
      if pin.base >= end { break }
      guard pin.base >= start, pin.length <= end - pin.base, r.type == 2, r.ordinaryWritableRAM,
        emit(start, pin.base, kind, r.attributes, &count),
        emit(pin.base, pin.base + pin.length, pin.kind, r.attributes, &count)
      else { return nil }
      pins += 1
      start = pin.base + pin.length
    }
    guard emit(start, end, kind, r.attributes, &count) else { return nil }
  }
  return pins == 2 ? count : nil
}

#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  /// Finalize in the boot CPU's physical identity map after successful firmware
  /// exit. Both allocations are exclusive, disjoint from scratch and live until
  /// the kernel takes over. No executable mapping or signature claim is implied.
  @unsafe public func writeHandoff(
    _ initial: BootInfo, regions: UnsafeBufferPointer<FirmwareRegion>,
    storage: borrowing FirmwareBootServices.LoaderPages,
    archive: borrowing FirmwareBootServices.LoaderPages, archiveBytes: UInt64,
    debugFixedGeneration: DebugQEMUFixedGeneration? = nil, mapCapacity: Int? = nil
  ) -> Bool {
    guard storage.length >= 8192, storage.length <= UInt64(Int.max),
      let destination = UnsafeMutableRawPointer(bitPattern: UInt(storage.base)),
      archiveBytes > 0, archiveBytes <= archive.length
    else { return false }
    let block = UnsafeMutableRawBufferPointer(start: destination, count: 4096)
    block[0] = 0
    let capacity = mapCapacity ?? Int(storage.length) - 4096
    guard capacity >= 32, capacity <= Int(storage.length) - 4096 else { return false }
    let map = UnsafeMutableRawBufferPointer(start: destination.advanced(by: 4096), count: capacity)
    guard
      let n = writeHandoffMap(
        regions,
        archive: LoaderExtent(base: archive.base, length: archive.length, kind: 7),
        handoff: LoaderExtent(base: storage.base, length: storage.length, kind: 8), into: map)
    else { return false }
    var info = initial
    info.bootSet = archive.base
    info.bootSetSize = archiveBytes
    info.mapAddress = storage.base + 4096
    info.mapCount = UInt64(n)
    guard validBootInfo(info) else { return false }
    for i in 1..<4096 { block[i] = bootInfoByte(info, offset: UInt64(i)) }
    block[0] = bootInfoByte(info, offset: 0)
    if let debugFixedGeneration, !debugFixedGeneration.encode(in: block) {
      block[0] = 0
      return false
    }
    return true
  }
#endif
