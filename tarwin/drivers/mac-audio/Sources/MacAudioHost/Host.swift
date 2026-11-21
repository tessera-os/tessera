import CoreAudio
import Dispatch
import HostedDeviceWire
import MacAudioWire
import Synchronization

public final class MacAudioHost: @unchecked Sendable {
  public let playback: AudioProcessor?
  public let capture: AudioProcessor?
  private let channel: any HostedDeviceChannel
  private let useHAL: Bool
  private let queue = DispatchQueue(label: "tarwin.audio.control", qos: .userInteractive)
  private var units: [HALUnit?] = [nil,nil]
  private var states: [AudioStreamState] = [.closed,.closed]
  private var lastOverruns: [UInt64] = [0,0], lastUnderruns: [UInt64] = [0,0]
  private var timer: DispatchSourceTimer?
  private var listener: AudioObjectPropertyListenerBlock?
  public private(set) var lastDeviceError: AudioError?
  public init(channel: any HostedDeviceChannel, playback: AudioRing?, capture: AudioRing?, useHAL: Bool = true,
    automaticPositions: Bool = true) {
    self.channel = channel; self.useHAL = useHAL
    self.playback = playback.map { AudioProcessor(ring: $0) }
    self.capture = capture.map { AudioProcessor(ring: $0) }
    if let p = self.playback { units[0] = HALUnit(processor: p, endpoint: .playback) }
    if let c = self.capture { units[1] = HALUnit(processor: c, endpoint: .capture) }
    channel.onReceive = { [weak self] bytes in
      guard let self else { return }
      self.queue.sync { self.receive(bytes) }
    }
    if automaticPositions {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .microseconds(100))
      timer.setEventHandler { [weak self] in self?.publishPositions() }
      self.timer = timer; timer.resume()
    }
    if useHAL { installListeners() }
  }
  deinit {
    timer?.cancel()
    if let listener {
      for endpoint in AudioEndpoint.allCases {
        var address = Self.address(endpoint)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
      }
    }
  }
  private static func address(_ endpoint: AudioEndpoint) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: endpoint == .playback
      ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }
  private func installListeners() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      for endpoint in AudioEndpoint.allCases {
        let i = Int(endpoint.rawValue - 1)
        guard self.states[i] == .running || self.states[i] == .draining else { continue }
        do {
          try self.units[i]?.start()
          self.processor(endpoint)?.running.store(true, ordering: .releasing)
          self.lastDeviceError = nil
        }
        catch { self.lastDeviceError = error as? AudioError; self.processor(endpoint)?.running.store(false, ordering: .releasing) }
      }
    }
    listener = block
    for endpoint in AudioEndpoint.allCases {
      var address = Self.address(endpoint)
      let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
      if status != noErr { lastDeviceError = .coreAudio(status) }
    }
  }
  public static func hasDefaultDevice(_ endpoint: AudioEndpoint) -> Bool {
    (try? HALUnit.defaultDevice(endpoint)) != nil
  }
  private func processor(_ endpoint: AudioEndpoint) -> AudioProcessor? { endpoint == .playback ? playback : capture }
  /// Explicit hardware smoke/integration entry; normal clients use family-2 commands.
  public func startHardware(_ endpoint: AudioEndpoint) throws {
    try queue.sync {
      guard let p = processor(endpoint) else { throw AudioError.configuration }
      p.running.store(true, ordering: .releasing)
      do { if useHAL { try units[Int(endpoint.rawValue-1)]?.start() } }
      catch { p.running.store(false, ordering: .releasing); throw error }
      states[Int(endpoint.rawValue-1)] = .running
    }
  }
  public func stopHardware(_ endpoint: AudioEndpoint) {
    queue.sync {
      units[Int(endpoint.rawValue-1)]?.close()
      processor(endpoint)?.running.store(false, ordering: .releasing)
      states[Int(endpoint.rawValue-1)] = .stopped
    }
  }
  public func shutdown() {
    stopHardware(.playback); stopHardware(.capture)
    queue.sync { timer?.cancel(); timer = nil }
  }
  private func receive(_ bytes: UnsafeRawBufferPointer) {
    guard let f = FrameView(bytes), f.family == 2 else { return }
    if f.kind == Wire.ping, f.payload.isEmpty {
      AudioWire.send(channel, kind: Wire.pong, sequence: f.sequence, timestampNs: f.timestampNs, payloadSize: 0) { _ in }; return
    }
    guard f.payload.count >= 4, let endpoint = AudioEndpoint(rawValue: UInt32(Wire.read(f.payload,0,4))),
      let p = processor(endpoint) else { return }
    var status: UInt16 = 0
    do { try apply(f, endpoint: endpoint, processor: p) }
    catch AudioError.malformed { status = 1 }
    catch AudioError.configuration { status = 2 }
    catch AudioError.state { status = 3 }
    catch AudioError.noDevice { status = 5 }
    catch { status = 4 }
    AudioWire.send(channel, kind: AudioKind.status, sequence: f.sequence, payloadSize: 8) { out in
      Wire.write(UInt64(endpoint.rawValue), to: out, at: 0, width: 4)
      Wire.write(UInt64(f.kind), to: out, at: 4, width: 2)
      Wire.write(UInt64(status), to: out, at: 6, width: 2)
    }
  }
  private func apply(_ f: FrameView, endpoint: AudioEndpoint, processor p: AudioProcessor) throws {
    let i = Int(endpoint.rawValue-1), payload = f.payload
    let expected = f.kind == AudioKind.configure ? 20 : (f.kind == AudioKind.volume || f.kind == AudioKind.mute ? 8 : 4)
    guard payload.count == expected else { throw AudioError.malformed }
    switch f.kind {
    case AudioKind.open:
      guard states[i] == .closed else { throw AudioError.state }; states[i] = .open
    case AudioKind.configure:
      guard [.open,.configured,.stopped].contains(states[i]) else { throw AudioError.state }
      guard let config = AudioWire.configuration(payload), config == p.ring.configuration,
        Wire.read(payload,16,4) == UInt64(p.ring.capacity) else { throw AudioError.configuration }
      states[i] = .configured
    case AudioKind.start:
      guard [.configured,.stopped].contains(states[i]) else { throw AudioError.state }
      p.draining.store(false, ordering: .releasing); p.running.store(true, ordering: .releasing)
      do { if useHAL { try units[i]?.start() } }
      catch { p.running.store(false, ordering: .releasing); throw error }
      states[i] = .running
    case AudioKind.stop:
      guard [.running,.draining].contains(states[i]) else { throw AudioError.state }
      units[i]?.close(); p.running.store(false, ordering: .releasing)
      p.draining.store(false, ordering: .releasing); states[i] = .stopped
    case AudioKind.drain:
      guard endpoint == .playback, states[i] == .running else { throw AudioError.state }
      p.draining.store(true, ordering: .releasing); states[i] = .draining
    case AudioKind.volume:
      let volume = Float(bitPattern: UInt32(Wire.read(payload,4,4)))
      guard states[i] != .closed, volume.isFinite, (0...1).contains(volume) else { throw AudioError.configuration }
      p.gainBits.store(volume.bitPattern, ordering: .releasing)
    case AudioKind.mute:
      guard states[i] != .closed, Wire.read(payload,4,4) <= 1 else { throw AudioError.configuration }
      p.muted.store(Wire.read(payload,4,4) != 0, ordering: .releasing)
    case AudioKind.close:
      units[i]?.close(); p.running.store(false, ordering: .releasing)
      p.draining.store(false, ordering: .releasing); states[i] = .closed
    default: throw AudioError.malformed
    }
  }
  public func flushPositions() { queue.sync { publishPositions() } }
  private func publishPositions() {
    for endpoint in AudioEndpoint.allCases {
      let i = Int(endpoint.rawValue-1)
      guard let p = processor(endpoint), states[i] == .running || states[i] == .draining else { continue }
      let timestamp = p.hostTimeNs.load(ordering: .acquiring)
      AudioWire.send(channel, kind: AudioKind.position, timestampNs: timestamp, payloadSize: 28) { out in
        Wire.write(UInt64(endpoint.rawValue), to: out, at: 0, width: 4)
        Wire.write(p.position.load(ordering: .relaxed), to: out, at: 4, width: 8)
        Wire.write(timestamp, to: out, at: 12, width: 8)
        Wire.write(p.ring.latencyNs, to: out, at: 20, width: 8)
      }
      let over = p.ring.overruns, under = p.ring.underruns
      if over != lastOverruns[i] || under != lastUnderruns[i] {
        AudioWire.send(channel, kind: AudioKind.gap, payloadSize: 20) { out in
          Wire.write(UInt64(endpoint.rawValue), to: out, at: 0, width: 4)
          Wire.write(over, to: out, at: 4, width: 8); Wire.write(under, to: out, at: 12, width: 8)
        }
        lastOverruns[i] = over; lastUnderruns[i] = under
      }
      if states[i] == .draining, !p.running.load(ordering: .acquiring) {
        units[i]?.close(); states[i] = .stopped
      }
    }
  }
}
