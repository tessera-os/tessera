import KCore

// Single SHA-256 bank for platforms which advertise it in both the TPM
// and the Spec ID event. Do not use as a substitute for a required bank
// or for DICE. The caller supplies the digest of the measured bytes.
func measuredRegister(_ pcr: UInt32) -> Bool { return pcr >= 8 && pcr <= 12 }

func putField<B: ByteBuffer>(_ b: inout B, p: UInt64, bytes: UInt64, value: UInt64, big: Bool) {
  var i: UInt64 = 0
  while i < bytes {
    let shift = big ? bytes - i - 1 : i
    b.putByte(p + i, value: UInt8((value >> (8 * shift)) & 255))
    i += 1
  }
}

// TPM2_PCR_Extend with an empty password authorization session. Only
// works when the PCR policy permits that session at the current locality.
public func encodePcrExtend<H: ByteSource, B: ByteBuffer>(
  _ pcr: UInt32, digest: H, command: inout B
) -> UInt64 {
  if !measuredRegister(pcr) || digest.byteCount() != 32 || command.byteCount() < 65 { return 0 }
  putField(&command, p: 0, bytes: 2, value: 0x8002, big: true)
  putField(&command, p: 2, bytes: 4, value: 65, big: true)
  putField(&command, p: 6, bytes: 4, value: 0x182, big: true)
  putField(&command, p: 10, bytes: 4, value: UInt64(pcr), big: true)
  putField(&command, p: 14, bytes: 4, value: 9, big: true)
  putField(&command, p: 18, bytes: 4, value: 0x4000_0009, big: true)
  putField(&command, p: 22, bytes: 5, value: 0, big: true)
  putField(&command, p: 27, bytes: 4, value: 1, big: true)
  putField(&command, p: 31, bytes: 2, value: 0x000b, big: true)
  var i: UInt64 = 0
  while i < 32 {
    command.putByte(33 + i, value: digest.byteAt(i))
    i += 1
  }
  return 65
}

func validResponse<R: ByteSource>(_ reply: R, received: UInt64) -> Bool {
  if received != 19 || reply.byteCount() < received || reply.byteAt(0) != 128
    || reply.byteAt(1) != 2 || reply.byteAt(5) != 19 || reply.byteAt(16) != 1
  {
    return false
  }
  var i: UInt64 = 2
  while i < 19 {
    if i != 5 && i != 16 && reply.byteAt(i) != 0 { return false }
    i += 1
  }
  return true
}

public func pcrExtendSucceeded<R: ByteSource>(_ reply: R) -> Bool {
  return validResponse(reply, received: reply.byteCount())
}

// Crypto-agile TCG_PCR_EVENT2 (EV_IPL). Stage in unused log capacity
// before extending; publish the new end only on validated TPM success.
// Firmware owns the Spec ID header and the existing log. A transport loss
// after submission has unknown outcome: do not retry or continue boot.
public func stagePcrEvent<H: ByteSource, E: ByteSource, B: ByteBuffer>(
  _ pcr: UInt32, digest: H, event: E, log: inout B, pos: UInt64
) -> UInt64 {
  let length = event.byteCount()
  if !measuredRegister(pcr) || digest.byteCount() != 32 || length > 0xffff_ffff
    || pos > log.byteCount() || 50 + length > log.byteCount() - pos
  {
    return 0
  }
  putField(&log, p: pos, bytes: 4, value: UInt64(pcr), big: false)
  putField(&log, p: pos + 4, bytes: 4, value: 13, big: false)
  putField(&log, p: pos + 8, bytes: 4, value: 1, big: false)
  putField(&log, p: pos + 12, bytes: 2, value: 11, big: false)
  var i: UInt64 = 0
  while i < 32 {
    log.putByte(pos + 14 + i, value: digest.byteAt(i))
    i += 1
  }
  putField(&log, p: pos + 46, bytes: 4, value: length, big: false)
  i = 0
  while i < length {
    log.putByte(pos + 50 + i, value: event.byteAt(i))
    i += 1
  }
  return pos + 50 + length
}

// In-place command buffer. submit performs exactly one transaction,
// replaces its prefix with the reply and returns the actual received size.
public protocol TpmPort: ByteBuffer {
  mutating func submit(_ commandSize: UInt64) -> UInt64
}

func tpmHeader<P: TpmPort>(_ p: inout P, _ tag: UInt64, _ code: UInt64, _ size: UInt64) {
  putField(&p, p: 0, bytes: 2, value: tag, big: true)
  putField(&p, p: 2, bytes: 4, value: size, big: true)
  putField(&p, p: 6, bytes: 4, value: code, big: true)
}

func tpmSuccess<P: TpmPort>(_ p: P, _ size: UInt64, tag: UInt64) -> Bool {
  size >= 10 && size <= p.byteCount() && big(p, p: 0, n: 2) == tag
    && big(p, p: 2, n: 4) == size && big(p, p: 6, n: 4) == 0
}

public struct MeasurementLog {
  public internal(set) var used: UInt64
  public internal(set) var stopped: Bool

  public init(used: UInt64, stopped: Bool) {
    self.used = used
    self.stopped = stopped
  }
}

// Caller serializes TPM access and log publication (also across CPUs).
// A stopped log cannot be continued, even if the transport later recovers.
public func extendAndRecord<P: TpmPort, H: ByteSource, E: ByteSource, B: ByteBuffer>(
  _ port: inout P, state: inout MeasurementLog, log: inout B, pcr: UInt32, digest: H, event: E
) -> Bool {
  if state.stopped { return false }
  let end = stagePcrEvent(pcr, digest: digest, event: event, log: &log, pos: state.used)
  let size = encodePcrExtend(pcr, digest: digest, command: &port)
  if end == 0 || size == 0 {
    state.stopped = true
    return false
  }
  let received = port.submit(size)
  if !validResponse(port, received: received) {
    state.stopped = true
    return false
  }
  state.used = end
  return true
}
