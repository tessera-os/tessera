import TarwinBoot
import TarwinW0Verify

/// A single boot CPU owns all conventional pages after EFI exit and before
/// opening its allocator. With the cold DMA fence still in force, claim one
/// run for the log; keep it out of all later frame pools until shutdown.
struct W1ColdLogLayout {
  let source, storage, privatePages: Range<UInt64>

  init?(boot: BootInfo, map: UnsafeRawBufferPointer, privateBytes: UInt64 = 0) {
    let ram: Range<UInt64> = 0x4000_0000..<0x6000_0000
    let size = boot.logSize
    guard privateBytes <= 32 << 20, privateBytes & 16383 == 0,
      size > 0, size <= 64 * 4096, boot.logAddress & 4095 == 0,
      ram.contains(boot.logAddress), size <= ram.upperBound - boot.logAddress,
      boot.mapCount > 0, boot.mapCount <= UInt64(map.count / 32) else { return nil }
    let log = boot.logAddress..<boot.logAddress + size
    let logLength = (size + 512 + 16383) & ~UInt64(16383)
    let length = logLength + privateBytes
    var cursor = beginMemoryMap(boot.mapCount, available: UInt64(map.count))
    var held = false
    var dest: Range<UInt64>?
    for i in 0..<Int(boot.mapCount) {
      func word(_ j: Int) -> UInt64 {
        .init(littleEndian: map.loadUnaligned(fromByteOffset: i * 32 + j, as: UInt64.self))
      }
      let base = word(0), bytes = word(8), flags = word(16)
      guard acceptRegion(&cursor, base: base, length: bytes, typeAndAttributes: flags,
        reserved: word(24)) else { return nil }
      let attrs = flags >> 32
      guard attrs & 8 != 0, attrs & 0x6_b000 == 0 else { continue }
      let end = base + bytes
      switch UInt32(truncatingIfNeeded: flags) {
      case 1:
        if base <= log.lowerBound && end >= log.upperBound { held = true }
      case 0 where dest == nil && base < ram.upperBound:
        let first = (max(base, ram.lowerBound) + 16383) & ~UInt64(16383)
        let last = min(end, ram.upperBound)
        if first <= last, length <= last - first { dest = first..<first + length }
      default: break
      }
    }
    guard completeMemoryMap(cursor), held, let dest, !dest.overlaps(log) else { return nil }
    source = log
    storage = dest.lowerBound..<dest.lowerBound + logLength
    privatePages = storage.upperBound..<dest.upperBound
  }
}

/// Only for the non-restorable PC Client cold profile: static PCRs 8–10
/// start at zero. Replay the copied prefix independently of the TPM.
func confirmedColdPCR10(_ bytes: UnsafeRawBufferPointer, archive: InlineArray<32, UInt8>,
  configuration: InlineArray<32, UInt8>, matchesPCR: (UInt8, InlineArray<32, UInt8>) -> Bool)
  -> InlineArray<32, UInt8>? {
  guard let fmt = EventLogFormat(bytes) else { return nil }
  let reset = InlineArray<32, UInt8>(repeating: 0)
  var pcr8 = reset, pcr9 = reset
  var pos = fmt.firstEvent
  var nextPCR: UInt32 = 8
  while pos < bytes.count {
    guard let event = fmt.event(bytes, at: pos), event.pcr != 10 else { return nil }
    func matches(_ label: StaticString) -> Bool {
      guard label.utf8CodeUnitCount == event.payload.count else { return false }
      for i in 0..<event.payload.count
      where bytes[event.payload.lowerBound + i] != label.utf8Start[i] { return false }
      return true
    }
    let isArchive = matches("Tarwin boot set")
    if isArchive || matches("Tarwin boot configuration") {
      guard event.type == 13, event.pcr == nextPCR, event.pcr == (isArchive ? 8 : 9)
      else { return nil }
      for i in 0..<32 where bytes[event.sha256 + i] != (isArchive ? archive[i] : configuration[i]) {
        return nil
      }
      nextPCR += 1
    }
    if event.type != 3 && (event.pcr == 8 || event.pcr == 9) { // EV_NO_ACTION does not extend.
      var digest = InlineArray<32, UInt8>(repeating: 0)
      for i in 0..<32 { digest[i] = bytes[event.sha256 + i] }
      if event.pcr == 8 { pcr8 = replaySHA256PCR(previous: pcr8, event: digest) }
      else { pcr9 = replaySHA256PCR(previous: pcr9, event: digest) }
    }
    pos = event.payload.upperBound
  }
  guard pos == bytes.count && nextPCR == 10, matchesPCR(8, pcr8), matchesPCR(9, pcr9),
    matchesPCR(10, reset) else { return nil }
  return reset
}
