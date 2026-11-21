public enum AudioState { case idle, configured, prepared, started, stopped }
public struct PcmStream {
  public let id: UInt64
  public let maxBuffer: UInt64
  public let input: Bool
  public internal(set) var state: AudioState = .idle
  public internal(set) var period: UInt64 = 0
  public internal(set) var buffer: UInt64 = 0
  public internal(set) var frame: UInt64 = 0
  public internal(set) var pending: UInt64 = 0

  public init(id: UInt64, maxBuffer: UInt64, input: Bool) {
    self.id = id
    self.maxBuffer = maxBuffer
    self.input = input
  }

  // This profile advertises mono/stereo S16_LE at 48 kHz with message queues,
  // not shared-memory audio. Bind transition to the host audio service of THIS VM.
  public mutating func control(
    _ cmd: [UInt8], _ granted: Bool,
    _ transition: (UInt64, UInt64, UInt64, UInt64) -> Bool
  ) -> UInt64 {
    if !granted { return 0x8003 }
    if cmd.count < 8 || vword(cmd, 4, 4) != id { return 0x8001 }
    let op = vword(cmd, 0, 4)
    if op == 257 {
      if cmd.count != 24 || !(state == .idle || state == .configured || state == .stopped)
        || pending != 0
      {
        return 0x8001
      }
      let bytes = vword(cmd, 8, 4)
      let step = vword(cmd, 12, 4)
      let channels = UInt64(cmd[20])
      if channels < 1 || channels > 2 || cmd[21] != 5 || cmd[22] != 7 || vword(cmd, 16, 4) != 0 {
        return 0x8002
      }
      if step == 0 || bytes < step || bytes > maxBuffer || bytes % step != 0
        || step % (channels * 2) != 0
      {
        return 0x8001
      }
      if !transition(op, bytes, step, channels) { return 0x8003 }
      buffer = bytes
      period = step
      frame = channels * 2
      state = .configured
      return 0x8000
    }
    if cmd.count != 8 { return 0x8001 }
    let next: AudioState
    switch op {
    case 258:
      if state != .configured && state != .stopped && state != .prepared { return 0x8001 }
      next = AudioState.prepared
    case 259:
      if (state != .prepared && state != .stopped) || pending != 0 { return 0x8001 }
      next = AudioState.configured

    case 260:
      if state != .prepared && state != .stopped { return 0x8001 }
      next = AudioState.started
    case 261:
      if state != .started { return 0x8001 }
      next = AudioState.stopped
    default: return 0x8002
    }
    if !transition(op, buffer, period, frame / 2) { return 0x8003 }
    state = next
    return 0x8000
  }
  public mutating func submit(_ bytes: UInt64, _ rx: Bool, _ grantLive: Bool) -> Bool {
    if !grantLive || rx != input || (state != .prepared && state != .started) || frame == 0
      || bytes == 0 || bytes % frame != 0 || bytes > buffer - pending
    {
      return false
    }
    pending += bytes
    return true
  }
  // Call after the host has consumed/filled the entire pinned transfer.
  public mutating func complete(_ bytes: UInt64) -> Bool {
    if bytes == 0 || bytes > pending || frame == 0 || bytes % frame != 0 { return false }
    pending -= bytes
    return true
  }
}
