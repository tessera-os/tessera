import HostedDeviceWire

public final class MacHIDDriver {
  public let ring: InputRing
  private let channel: any HostedDeviceChannel
  private var wheelRemainder: Int64 = 0
  private var panRemainder: Int64 = 0
  private var scrollUnit: UInt16 = 0
  public init(channel: any HostedDeviceChannel, ring: InputRing) {
    self.channel = channel; self.ring = ring
    channel.onReceive = { [weak self] in self?.receive($0) }
  }
  public func receive(_ bytes: UnsafeRawBufferPointer) {
    guard let frame = FrameView(bytes), frame.family == 1 else { return }
    if frame.kind == Wire.ping, frame.payload.isEmpty {
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { storage in
        let out = UnsafeMutableRawBufferPointer(storage)
        _ = FrameView.encode(family: 1, kind: Wire.pong, sequence: frame.sequence,
          timestampNs: frame.timestampNs, payload: .init(start: nil, count: 0), into: out)
        channel.send(frame: UnsafeRawBufferPointer(out))
      }
      return
    }
    let size: Int
    switch frame.kind {
    case HIDKind.keyboard: size = 8
    case HIDKind.pointer: size = 17
    case HIDKind.tablet: size = 13
    case HIDKind.gesture: size = 17
    default: return
    }
    guard frame.payload.count == size else { return }
    var report = InputReportRecord()
    report.deviceId = UInt32(frame.kind); report.timestampNs = frame.timestampNs
    report.reportLength = UInt16(frame.kind == HIDKind.pointer ? 9 : size)
    if frame.kind == HIDKind.pointer {
      for i in 0..<5 { report.bytes[i] = frame.payload[i] }
      if scrollUnit != frame.flags & 1 {
        wheelRemainder = 0; panRemainder = 0; scrollUnit = frame.flags & 1
      }
      func delta(_ offset: Int, _ remainder: inout Int64) -> UInt16 {
        let value = Int64(Int32(bitPattern: UInt32(Wire.read(frame.payload, offset, 4)))) + remainder
        let integral = max(-32768, min(32767, value / 65536))
        remainder = value % 65536
        return UInt16(bitPattern: Int16(integral))
      }
      let wheel = delta(5, &wheelRemainder), pan = delta(9, &panRemainder)
      report.bytes[5] = UInt8(truncatingIfNeeded: wheel); report.bytes[6] = UInt8(wheel >> 8)
      report.bytes[7] = UInt8(truncatingIfNeeded: pan); report.bytes[8] = UInt8(pan >> 8)
    } else {
      for i in 0..<size { report.bytes[i] = frame.payload[i] }
    }
    _ = ring.push(report)
    if frame.kind == HIDKind.pointer {
      var absolute = InputReportRecord()
      absolute.deviceId = 3; absolute.reportLength = 13; absolute.timestampNs = frame.timestampNs
      absolute.bytes[0] = 2
      for i in 0..<4 { absolute.bytes[1 + i] = frame.payload[13 + i] }
      _ = ring.push(absolute)
    }
  }
  public func setLEDs(_ leds: UInt8, sequence: UInt64 = 0, timestampNs: UInt64 = 0) {
    var value = leds & 0x1f
    withUnsafeBytes(of: &value) { payload in
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 33) { storage in
        let out = UnsafeMutableRawBufferPointer(storage)
        _ = FrameView.encode(family: 1, kind: HIDKind.leds, sequence: sequence,
          timestampNs: timestampNs, payload: payload, into: out)
        channel.send(frame: UnsafeRawBufferPointer(out))
      }
    }
  }
}
