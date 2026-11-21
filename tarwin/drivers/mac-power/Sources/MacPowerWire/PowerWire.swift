import HostedDeviceWire
import TarwinArchHosted

public enum PowerSourceKind: UInt32, Sendable { case battery = 1, mains = 2, ups = 3 }
public struct PowerSourceSample: Equatable, Sendable {
  public let id: UInt32
  public let kind: PowerSourceKind
  public let percent: UInt32
  public let isPresent: Bool
  public let online: Bool
  public let charging: Bool
  public let full: Bool
  public let timeToEmpty: UInt64
  public let timeToFull: UInt64
  public init?(id: UInt32, kind: PowerSourceKind, percent: UInt32 = .max, isPresent: Bool = true,
    online: Bool, charging: Bool = false, full: Bool = false, timeToEmpty: UInt64 = 0, timeToFull: UInt64 = 0) {
    guard percent <= 100 || percent == .max else { return nil }
    self.id = id; self.kind = kind; self.percent = percent; self.isPresent = isPresent
    self.online = online; self.charging = charging; self.full = full
    self.timeToEmpty = timeToEmpty; self.timeToFull = timeToFull
  }
  public static let mains = PowerSourceSample(id: 0, kind: .mains, online: true)!
  public init?(_ bytes: UnsafeRawBufferPointer) {
    guard bytes.count == 32, let kind = PowerSourceKind(rawValue: UInt32(Wire.read(bytes,4,4))) else { return nil }
    let flags = Wire.read(bytes,12,4)
    guard flags & ~UInt64(15) == 0 else { return nil }
    self.init(id: UInt32(Wire.read(bytes,0,4)), kind: kind, percent: UInt32(Wire.read(bytes,8,4)),
      isPresent: flags & 1 != 0, online: flags & 2 != 0, charging: flags & 4 != 0,
      full: flags & 8 != 0, timeToEmpty: Wire.read(bytes,16,8), timeToFull: Wire.read(bytes,24,8))
  }
  public func encode(into bytes: UnsafeMutableRawBufferPointer) {
    precondition(bytes.count >= 32)
    Wire.write(UInt64(id), to: bytes, at: 0, width: 4)
    Wire.write(UInt64(kind.rawValue), to: bytes, at: 4, width: 4)
    Wire.write(UInt64(percent), to: bytes, at: 8, width: 4)
    let flags: UInt64 = (isPresent ? 1 : 0) | (online ? 2 : 0) | (charging ? 4 : 0) | (full ? 8 : 0)
    Wire.write(flags, to: bytes, at: 12, width: 4)
    Wire.write(timeToEmpty, to: bytes, at: 16, width: 8)
    Wire.write(timeToFull, to: bytes, at: 24, width: 8)
  }
}
public enum PowerKind {
  public static let sources: UInt16 = 1, environment: UInt16 = 2, sleep: UInt16 = 3, wake: UInt16 = 4
}
public enum PowerSystemEvent: Sendable { case sleep, wake }
public enum PowerWire {
  public static let clock = HostClock()
  public static func send(_ channel: any HostedDeviceChannel, kind: UInt16, sequence: UInt64 = 0,
    timestampNs: UInt64? = nil, payload: UnsafeRawBufferPointer) {
    guard payload.count <= 1028 else { return }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1060) { storage in
      let bytes = UnsafeMutableRawBufferPointer(storage)
      if let count = FrameView.encode(family: 3, kind: kind, sequence: sequence,
        timestampNs: timestampNs ?? clock.monotonicNanos(), payload: payload, into: bytes) {
        channel.send(frame: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
      }
    }
  }
}
