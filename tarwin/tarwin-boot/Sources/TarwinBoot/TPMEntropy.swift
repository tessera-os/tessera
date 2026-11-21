import KCore

/// Read 32 bytes using TPM2_GetRandom under exclusive access. Success says
/// nothing about whether the platform has enrolled a physical entropy source.
/// Keep the sample private and disjoint from the transport's command buffer.
/// An error clears the sample; no stale or partial bytes are reported as fresh.
@available(macOS 26, *)
public func readTPMEntropy32<P: TpmPort>(_ port: inout P, into sample: inout InlineArray<32, UInt8>)
  -> Bool
{
  let capacity = port.byteCount()
  guard (44...4096).contains(capacity) else {
    sample = .init(repeating: 0)
    return false
  }
  var filled = 0
  defer {
    if filled != 32 { sample = .init(repeating: 0) }
    for i in 0..<capacity { port.putByte(i, value: 0) }
  }
  while filled < 32 {
    let need = UInt64(32 - filled)
    tpmHeader(&port, 0x8001, 0x17b, 12)
    putField(&port, p: 10, bytes: 2, value: need, big: true)
    let size = port.submit(12)
    guard size > 12, size <= 12 + need, tpmSuccess(port, size, tag: 0x8001),
      big(port, p: 10, n: 2) == size - 12
    else { return false }
    // A TPM may legitimately return fewer bytes. Every successful iteration
    // advances, so at most 32 commands can be issued, without retrying errors.
    for i in 12..<size {
      sample[filled] = port.byteAt(i)
      filled += 1
    }
  }
  return true
}
