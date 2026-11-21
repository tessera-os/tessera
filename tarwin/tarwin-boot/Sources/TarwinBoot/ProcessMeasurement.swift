import KCore

// TPM 2.0 part 3: HashSequenceStart(TPM_ALG_NULL), SequenceUpdate,
// EventSequenceComplete. The TPM hashes the entire pinned input and extends
// PCR 10; the log receives the digests returned by that same transaction.
private func emptyPW<P: TpmPort>(_ p: inout P, _ at: UInt64) {
  putField(&p, p: at, bytes: 4, value: 0x4000_0009, big: true)
  putField(&p, p: at + 4, bytes: 5, value: 0, big: true)
}

private func emptyAuth<P: TpmPort>(_ p: P, at: UInt64) -> Bool {
  big(p, p: at, n: 2) == 0 && p.byteAt(at + 2) <= 1 && big(p, p: at + 3, n: 2) == 0
}

/// The caller supplies the verifier's hash of the entire signed image and
/// a trusted SHA-256 PCR replay, independent of this TPM's command replies.
@available(macOS 26, *)
public struct PCR10Expectation {
  let image: InlineArray<32, UInt8>
  let before: InlineArray<32, UInt8>
  let after: InlineArray<32, UInt8>

  public init(
    imageSHA256: InlineArray<32, UInt8>, previousPCR: InlineArray<32, UInt8>,
    replayedPCR: InlineArray<32, UInt8>
  ) {
    image = imageSHA256
    before = previousPCR
    after = replayedPCR
  }
}

@available(macOS 26, *)
public func matchesBootPCR<P: TpmPort>(_ port: inout P, index: UInt8,
  expected: borrowing InlineArray<32, UInt8>)
  -> Bool
{
  guard index >= 8, index <= 10, port.byteCount() >= 62 else { return false }
  let mask = UInt8(1) << (index - 8)
  var command: InlineArray<20, UInt8> = [
    128, 1, 0, 0, 0, 20, 0, 0, 1, 126, 0, 0, 0, 1, 0, 11, 3, 0, 4, 0,
  ]
  var selection: InlineArray<16, UInt8> = [0, 0, 0, 1, 0, 11, 3, 0, 0, 0, 0, 0, 0, 1, 0, 32]
  command[18] = mask
  selection[8] = mask
  for i in 0..<20 { port.putByte(UInt64(i), value: command[i]) }
  let n = port.submit(20)
  guard n == 62, tpmSuccess(port, n, tag: 0x8001) else { return false }
  for i in 0..<16 where port.byteAt(UInt64(i + 14)) != selection[i] { return false }
  for i in 0..<32 where port.byteAt(UInt64(i + 30)) != expected[i] { return false }
  return true
}

/// A single TPM2_PCR_Read snapshot; reject a partial selection even if one digest matches.
@available(macOS 26, *)
public func matchesFirmwarePCRs<P: TpmPort>(_ port: inout P,
  archive: borrowing InlineArray<32, UInt8>, configuration: borrowing InlineArray<32, UInt8>) -> Bool {
  guard port.byteCount() >= 96 else { return false }
  let cmd: InlineArray<20, UInt8> = [128, 1, 0, 0, 0, 20, 0, 0, 1, 126, 0, 0, 0, 1, 0, 11, 3, 0, 3, 0]
  for i in 0..<20 { port.putByte(UInt64(i), value: cmd[i]) }
  let n = port.submit(20)
  let selection: InlineArray<16, UInt8> = [0, 0, 0, 1, 0, 11, 3, 0, 3, 0, 0, 0, 0, 2, 0, 32]
  guard n == 96, tpmSuccess(port, n, tag: 0x8001), big(port, p: 62, n: 2) == 32 else { return false }
  for i in 0..<16 where port.byteAt(UInt64(i + 14)) != selection[i] { return false }
  for i in 0..<32 {
    guard port.byteAt(UInt64(i + 30)) == archive[i],
      port.byteAt(UInt64(i + 64)) == configuration[i] else { return false }
  }
  return true
}

/// Measure but do not authorize or enter a process. The caller must supply
/// the exact immutable authorized image, a disjoint private event log with
/// exclusive spare capacity, and serialized TPM access. Never retry after
/// failure. The original log prefix and published end remain unchanged.
@available(macOS 26, *)
@unsafe public func measureEarlyProcess<P: TpmPort>(
  _ image: UnsafeRawBufferPointer, expected: borrowing PCR10Expectation, port: inout P,
  state: inout MeasurementLog,
  log: UnsafeMutableRawBufferPointer, label: StaticString
) -> Bool {
  guard !state.stopped else { return false }
  state.stopped = true
  guard !image.isEmpty, image.count <= 8 << 20, port.byteCount() >= 256,
    state.used <= UInt64(log.count), (1...64).contains(label.utf8CodeUnitCount)
  else { return false }
  let start = Int(state.used)
  let prefix = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(log)[..<start])
  guard let fmt = EventLogFormat(prefix) else { return false }
  var pos = fmt.firstEvent
  while pos < start {
    guard let event = fmt.event(prefix, at: pos) else { return false }
    pos = event.payload.upperBound
  }
  // Reserve the exact Event2 size before any TPM command.
  let listBytes = fmt.digestListBytes
  let recordSize = 12 + listBytes + label.utf8CodeUnitCount
  guard recordSize <= log.count - start, matchesBootPCR(&port, index: 10, expected: expected.before)
  else { return false }
  tpmHeader(&port, 0x8001, 0x186, 14)
  putField(&port, p: 10, bytes: 4, value: 0x10, big: true)
  let began = port.submit(14)
  guard began == 14, tpmSuccess(port, began, tag: 0x8001), port.byteAt(10) == 0x80 else { return false }
  let handle = big(port, p: 10, n: 4)
  var consumed = 0
  let chunk = Int(min(1024, port.byteCount() - 42))
  while consumed < image.count {
    let size = min(chunk, image.count - consumed)
    let last = size == image.count - consumed
    let at: UInt64 = last ? 42 : 29
    let n = at + UInt64(size)
    tpmHeader(&port, 0x8002, last ? 0x185 : 0x15c, n)
    if last { putField(&port, p: 10, bytes: 4, value: 10, big: true) }
    let s: UInt64 = last ? 14 : 10
    putField(&port, p: s, bytes: 4, value: handle, big: true)
    putField(&port, p: s + 4, bytes: 4, value: last ? 18 : 9, big: true)
    emptyPW(&port, s + 8)
    if last { emptyPW(&port, s + 17) }
    putField(&port, p: at - 2, bytes: 2, value: UInt64(size), big: true)
    for i in 0..<size { port.putByte(at + UInt64(i), value: image[consumed + i]) }
    consumed += size
    let received = port.submit(n)
    guard tpmSuccess(port, received, tag: 0x8002) else { return false }
    if last {
      let end = UInt64(14 + listBytes)
      guard received == end + 10, big(port, p: 10, n: 4) == UInt64(listBytes),
        big(port, p: 14, n: 4) == UInt64(fmt.banks.nonzeroBitCount),
        emptyAuth(port, at: end), emptyAuth(port, at: end + 5)
      else { return false }
      func le(_ value: UInt32, _ offset: Int) {
        log.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
      }
      le(10, start)
      le(13, start + 4)
      le(UInt32(fmt.banks.nonzeroBitCount), start + 8)
      var idx: UInt64 = 18
      var out = start + 12
      var seen: UInt32 = 0
      while idx < end {
        guard end - idx >= 2 else { return false }
        let id = UInt16(big(port, p: idx, n: 2))
        guard let b = EventLogFormat.bank(id), seen & b.mask == 0, b.mask & fmt.banks != 0,
          UInt64(b.size) <= end - idx - 2
        else { return false }
        seen |= b.mask
        log[out] = UInt8(truncatingIfNeeded: id)
        log[out + 1] = UInt8(id >> 8)
        for i in 0..<b.size {
          let value = port.byteAt(idx + 2 + UInt64(i))
          if id == 11 {
            guard value == expected.image[i] else { return false }
          }
          log[out + 2 + i] = value
        }
        idx += UInt64(b.size + 2)
        out += b.size + 2
      }
      guard seen == fmt.banks, matchesBootPCR(&port, index: 10, expected: expected.after)
      else { return false }
      le(UInt32(label.utf8CodeUnitCount), out)
      for i in 0..<label.utf8CodeUnitCount { log[out + 4 + i] = label.utf8Start[i] }
      state.used += UInt64(recordSize)
      state.stopped = false
      return true
    }
    guard validResponse(port, received: received) else { return false }
  }
  return false
}
