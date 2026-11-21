import HostedDeviceWire
import MacAudioWire

public struct AudioStreamSnapshot {
  public var configuration: AudioConfiguration?
  public var ring: AudioRing?
  public var state: AudioStreamState = .closed
  public var volume: Float = 1
  public var muted = false
  public init() {}
}

/// Control calls and receive callbacks must be serialized by the owner.
public final class MacAudioDriver {
  private var streams = [AudioStreamSnapshot(), AudioStreamSnapshot()]
  private var channel: any HostedDeviceChannel
  private var sequence: UInt64 = 0
  public private(set) var playbackPosition: UInt64 = 0
  public private(set) var capturePosition: UInt64 = 0
  public private(set) var hostTimeNs: UInt64 = 0
  public private(set) var latencyNs: UInt64 = 0
  public private(set) var lastStatus: UInt16 = 0
  public var onGap: ((AudioEndpoint, UInt64, UInt64) -> Void)?
  public init(channel: any HostedDeviceChannel) {
    self.channel = channel
    channel.onReceive = { [weak self] in self?.receive($0) }
  }
  public func snapshot(_ endpoint: AudioEndpoint) -> AudioStreamSnapshot { streams[Int(endpoint.rawValue-1)] }
  private func command(_ kind: UInt16, _ endpoint: AudioEndpoint, size: Int = 4,
    fill: (UnsafeMutableRawBufferPointer) -> Void = { _ in }) {
    sequence &+= 1
    AudioWire.send(channel, kind: kind, sequence: sequence, payloadSize: size) { p in
      Wire.write(UInt64(endpoint.rawValue), to: p, at: 0, width: 4); fill(p)
    }
  }
  public func open(_ endpoint: AudioEndpoint) throws {
    let i = Int(endpoint.rawValue-1)
    guard streams[i].state == .closed else { throw AudioError.state }
    streams[i].state = .open; command(AudioKind.open, endpoint)
  }
  public func configure(_ endpoint: AudioEndpoint, ring: AudioRing) throws {
    let i = Int(endpoint.rawValue-1)
    guard [.open,.configured,.stopped].contains(streams[i].state) else { throw AudioError.state }
    streams[i].configuration = ring.configuration; streams[i].ring = ring; streams[i].state = .configured
    command(AudioKind.configure, endpoint, size: 20) { p in
      Wire.write(UInt64(ring.configuration.sampleRate), to: p, at: 4, width: 4)
      Wire.write(UInt64(ring.configuration.channels), to: p, at: 8, width: 4)
      Wire.write(UInt64(ring.configuration.format.rawValue), to: p, at: 12, width: 4)
      Wire.write(UInt64(ring.capacity), to: p, at: 16, width: 4)
    }
  }
  public func start(_ endpoint: AudioEndpoint) throws {
    let i = Int(endpoint.rawValue-1)
    guard [.configured,.stopped].contains(streams[i].state) else { throw AudioError.state }
    streams[i].state = .running; command(AudioKind.start, endpoint)
  }
  public func stop(_ endpoint: AudioEndpoint) throws {
    let i = Int(endpoint.rawValue-1)
    guard [.running,.draining].contains(streams[i].state) else { throw AudioError.state }
    streams[i].state = .stopped; command(AudioKind.stop, endpoint)
  }
  public func drain(_ endpoint: AudioEndpoint = .playback) throws {
    guard endpoint == .playback, snapshot(endpoint).state == .running else { throw AudioError.state }
    streams[0].state = .draining; command(AudioKind.drain, endpoint)
  }
  public func close(_ endpoint: AudioEndpoint) {
    streams[Int(endpoint.rawValue-1)] = AudioStreamSnapshot(); command(AudioKind.close, endpoint)
  }
  public func setVolume(_ value: Float, endpoint: AudioEndpoint = .playback) throws {
    guard value.isFinite, (0...1).contains(value), snapshot(endpoint).state != .closed else { throw AudioError.configuration }
    streams[Int(endpoint.rawValue-1)].volume = value
    command(AudioKind.volume, endpoint, size: 8) { Wire.write(UInt64(value.bitPattern), to: $0, at: 4, width: 4) }
  }
  public func setMuted(_ value: Bool, endpoint: AudioEndpoint = .playback) throws {
    guard snapshot(endpoint).state != .closed else { throw AudioError.state }
    streams[Int(endpoint.rawValue-1)].muted = value
    command(AudioKind.mute, endpoint, size: 8) { Wire.write(value ? 1 : 0, to: $0, at: 4, width: 4) }
  }
  /// H7 must re-send/re-map each snapshot's ring before calling this method.
  public func restore(on channel: any HostedDeviceChannel) throws {
    let saved = streams
    self.channel = channel; channel.onReceive = { [weak self] in self?.receive($0) }
    streams = [AudioStreamSnapshot(), AudioStreamSnapshot()]
    for endpoint in AudioEndpoint.allCases {
      let s = saved[Int(endpoint.rawValue-1)]
      guard s.state != .closed else { continue }
      try open(endpoint)
      if let ring = s.ring { try configure(endpoint, ring: ring) }
      try setVolume(s.volume, endpoint: endpoint); try setMuted(s.muted, endpoint: endpoint)
      if s.state == .running || s.state == .draining { try start(endpoint) }
      if s.state == .draining { try drain(endpoint) }
    }
  }
  public func receive(_ bytes: UnsafeRawBufferPointer) {
    guard let f = FrameView(bytes), f.family == 2 else { return }
    if f.kind == Wire.ping, f.payload.isEmpty {
      AudioWire.send(channel, kind: Wire.pong, sequence: f.sequence, timestampNs: f.timestampNs, payloadSize: 0) { _ in }; return
    }
    let p = f.payload
    guard p.count >= 4, let endpoint = AudioEndpoint(rawValue: UInt32(Wire.read(p,0,4))) else { return }
    switch f.kind {
    case AudioKind.position where p.count == 28:
      let position = Wire.read(p,4,8)
      if endpoint == .playback { playbackPosition = position } else { capturePosition = position }
      hostTimeNs = Wire.read(p,12,8); latencyNs = Wire.read(p,20,8)
      if snapshot(endpoint).state == .draining, snapshot(endpoint).ring?.availableFrames == 0 {
        streams[Int(endpoint.rawValue-1)].state = .stopped
      }
    case AudioKind.gap where p.count == 20:
      onGap?(endpoint, Wire.read(p,4,8), Wire.read(p,12,8))
    case AudioKind.status where p.count == 8:
      lastStatus = UInt16(Wire.read(p,6,2))
      if lastStatus != 0 { streams[Int(endpoint.rawValue-1)].state = .stopped }
    default: break
    }
  }
}
