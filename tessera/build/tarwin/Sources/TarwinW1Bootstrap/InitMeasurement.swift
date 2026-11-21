import TarwinBoot
import TarwinW0Verify

func exactMember(
  _ bytes: UnsafeRawBufferPointer, in archive: UnsafeRawBufferPointer,
  at range: Range<Int>, excluding log: UnsafeMutableRawBufferPointer
) -> Bool {
  guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= archive.count,
    range.count == bytes.count, let a = archive.baseAddress, let l = log.baseAddress,
    a.advanced(by: range.lowerBound) == bytes.baseAddress
  else { return false }
  let a0 = UInt(bitPattern: a)
  let l0 = UInt(bitPattern: l)
  return a0 <= l0 ? UInt(archive.count) <= l0 - a0 : UInt(log.count) <= a0 - l0
}

/// Post-exit W1 measurement, not permission to run. Pin the verifier's
/// immutable archive for the whole transaction; give this call exclusive
/// TPM access, disjoint scratch and the protected firmware-log copy.
/// previousPCR10 is trusted replay state, never sampled from the device
/// as its own reference. Failure forbids both launch and log publication.
@unsafe public func measureAuthorizedQEMUInit<P: TpmPort>(
  _ set: borrowing W1BootSet, in archive: UnsafeRawBufferPointer,
  previousPCR10: InlineArray<32, UInt8>, port: inout P,
  state: inout MeasurementLog, log: UnsafeMutableRawBufferPointer
) -> Bool {
  guard !state.stopped else { return false }
  guard exactMember(set.process.bytes, in: archive, at: set.process.range, excluding: log)
  else {
    state = MeasurementLog(used: state.used, stopped: true)
    return false
  }
  let digest = set.initSHA256
  let expected = PCR10Expectation(
    imageSHA256: digest, previousPCR: previousPCR10,
    replayedPCR: replaySHA256PCR(previous: previousPCR10, event: digest))
  return measureEarlyProcess(
    set.process.bytes, expected: expected, port: &port,
    state: &state, log: log, label: "tessera.init")
}
