public enum PanicCaptureResult { case unavailable, ramOnly, ramAndFirmware }

// The platform freezes the CPUs first. The read-only snapshots and tails must
// remain stable until both stores have finished. Never read an unbounded stack.
public protocol PanicSnapshots {
  var cpuCount: UInt32 { get }
  func registerByteCount(cpu: UInt32) -> UInt32
  func registerByte(cpu: UInt32, offset: UInt32) -> UInt8
  func frameCount(cpu: UInt32) -> UInt16
  func frame(cpu: UInt32, index: UInt16) -> UInt64
  var logBytes: UInt64 { get }
  var traceBytes: UInt64 { get }
  func logByte(_ offset: UInt64) -> UInt8
  func traceByte(_ offset: UInt64) -> UInt8
}

// TLV 1: cpu:u32, register bytes; TLV 2: cpu:u32, backtrace PCs:u64;
// TLVs 3 and 4: newest log and trace bytes. Integers are little endian.
// Reserve record headers for *every* CPU before obtaining payload data. A
// missing CPU snapshot never becomes a successful all-CPU panic capture.
public func capturePanic(
  _ snapshots: some PanicSnapshots, capacity: UInt64,
  put: (UInt64, UInt8) -> Void, persist: () -> Void,
  mirrorCommitted: (UInt64) -> Bool
) -> PanicCaptureResult {
  let cpus = snapshots.cpuCount
  guard cpus > 0 && cpus <= 4096 else { return .unavailable }
  let limit = min(capacity, PanicLayout.maxBytes)
  let logs = snapshots.logBytes
  let traces = snapshots.traceBytes
  var needed = PanicLayout.header + UInt64(cpus) * 18 + 10
  let tailMinimum = min(logs, 1) + min(traces, 1)
  guard needed + tailMinimum <= limit else { return .unavailable }
  var extraFrames: UInt64 = 0
  for cpu in 0..<cpus {
    let bytes = snapshots.registerByteCount(cpu: cpu)
    let frames = snapshots.frameCount(cpu: cpu)
    guard bytes > 0, frames <= 256 else { return .unavailable }
    let first = min(frames, 1)
    needed += UInt64(bytes) + UInt64(first) * 8
    extraFrames += UInt64(frames - first)
    guard needed + tailMinimum <= limit else { return .unavailable }
  }
  let budget = min(extraFrames, (limit - needed - tailMinimum) / 8)
  var seen: UInt64 = 0
  var assigned: UInt64 = 0

  var writer = PanicWriter(capacity: limit)
  guard writer.begin(put, persist) else { return .unavailable }
  for cpu in 0..<cpus {
    let registers = UInt64(snapshots.registerByteCount(cpu: cpu))
    guard
      writer.section(
        1, 4 + registers,
        { i in
          if i < 4 { return UInt8(truncatingIfNeeded: cpu >> (8 * i)) }
          return snapshots.registerByte(cpu: cpu, offset: UInt32(i - 4))
        }, put)
    else { return .unavailable }
    // Reserve each nonempty stack's top frame. Distribute the remaining
    // frame slots proportionally, so one deep stack cannot erase later CPUs.
    let depth = UInt64(snapshots.frameCount(cpu: cpu))
    let first = min(depth, 1)
    seen += depth - first
    let through = extraFrames == 0 ? 0 : seen * budget / extraFrames
    let frames = first + (through - assigned)
    assigned = through
    guard
      writer.section(
        2, 4 + frames * 8,
        { i in
          if i < 4 { return UInt8(truncatingIfNeeded: cpu >> (8 * i)) }
          let word = snapshots.frame(cpu: cpu, index: UInt16((i - 4) / 8))
          return UInt8(truncatingIfNeeded: word >> ((i - 4) % 8 * 8))
        }, put)
    else { return .unavailable }
  }

  let spare = limit - needed - budget * 8
  let traceReserved = min(traces, spare / 2)
  let logTail = min(logs, spare - traceReserved)
  let traceTail = min(traces, spare - logTail)
  guard writer.section(3, logTail, { snapshots.logByte(logs - logTail + $0) }, put),
    writer.section(4, traceTail, { snapshots.traceByte(traces - traceTail + $0) }, put),
    writer.commit(put, persist)
  else { return .unavailable }
  return mirrorCommitted(writer.cursor) ? .ramAndFirmware : .ramOnly
}
