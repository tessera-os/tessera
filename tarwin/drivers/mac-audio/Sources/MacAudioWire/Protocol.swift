import Darwin
import HostedDeviceWire
import TarwinArchHosted

public enum AudioEndpoint: UInt32, CaseIterable, Sendable { case playback = 1, capture = 2 }
public enum AudioKind {
  public static let open: UInt16 = 1, configure: UInt16 = 2, start: UInt16 = 3
  public static let stop: UInt16 = 4, drain: UInt16 = 5, volume: UInt16 = 6, mute: UInt16 = 7
  public static let close: UInt16 = 8
  public static let position: UInt16 = 0x100, gap: UInt16 = 0x101, status: UInt16 = 0x102
}
public enum AudioError: Error, Equatable { case state, configuration, malformed, noDevice, coreAudio(Int32) }
public enum AudioStreamState: Sendable { case closed, open, configured, running, stopped, draining }

public enum AudioWire {
  private static let clock = HostClock()
  public static func nowNs() -> UInt64 {
    clock.monotonicNanos()
  }
  public static func send(_ channel: any HostedDeviceChannel, kind: UInt16, sequence: UInt64 = 0,
    timestampNs: UInt64? = nil, payloadSize: Int, fill: (UnsafeMutableRawBufferPointer) -> Void) {
    guard (0...64).contains(payloadSize) else { return }
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { storage in
      storage.initialize(repeating: 0)
      let payload = UnsafeMutableRawBufferPointer(rebasing: UnsafeMutableRawBufferPointer(storage)[..<payloadSize])
      fill(payload)
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 96) { output in
        let bytes = UnsafeMutableRawBufferPointer(output)
        if let count = FrameView.encode(family: 2, kind: kind, sequence: sequence,
          timestampNs: timestampNs ?? nowNs(), payload: UnsafeRawBufferPointer(payload), into: bytes) {
          channel.send(frame: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
        }
      }
    }
  }
  public static func configuration(_ payload: UnsafeRawBufferPointer) -> AudioConfiguration? {
    guard payload.count == 20, let format = PCMFormat(rawValue: UInt32(Wire.read(payload, 12, 4))) else { return nil }
    return AudioConfiguration(sampleRate: UInt32(Wire.read(payload, 4, 4)),
      channels: UInt32(Wire.read(payload, 8, 4)), format: format)
  }
}
