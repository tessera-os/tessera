import HostedDeviceWire
import MacPowerWire
import TarwinPower

/// One serialized producer owns this driver and its pinned publication page.
public final class MacPowerDriver {
  private var writer: PowerPageWriter
  private let channel: any HostedDeviceChannel
  private var sources: InlineArray<32, PowerSourceSample> = .init(repeating: .mains)
  public private(set) var sourceCount = 0
  public private(set) var thermalBand: ThermalBand = .critical
  public private(set) var lowPower = false
  private var latestTimestamp: UInt64 = 0
  public var onPublished: (() -> Void)?
  public var onSystemEvent: ((PowerSystemEvent, UInt64) -> Void)?
  public init?(channel: any HostedDeviceChannel, initializing page: UnsafeMutableRawBufferPointer) {
    guard let writer = PowerPageWriter(initializing: page) else { return nil }
    self.writer = consume writer; self.channel = channel
    channel.onReceive = { [weak self] in self?.receive($0) }
  }
  public func source(at index: Int) -> PowerSourceSample? {
    guard index >= 0, index < sourceCount else { return nil }; return sources[index]
  }
  public static func thermalBand(rawValue: UInt32) -> ThermalBand? {
    switch rawValue { case 0: .nominal; case 1: .fair; case 2: .serious; case 3: .critical; default: nil }
  }
  public func receive(_ bytes: UnsafeRawBufferPointer) {
    guard let frame = FrameView(bytes), frame.family == 3 else { return }
    if frame.kind == Wire.ping, frame.payload.isEmpty {
      PowerWire.send(channel, kind: Wire.pong, sequence: frame.sequence, timestampNs: frame.timestampNs,
        payload: .init(start: nil, count: 0)); return
    }
    guard frame.timestampNs >= latestTimestamp else { return }
    let p = frame.payload
    switch frame.kind {
    case PowerKind.sources:
      guard p.count >= 4 else { return }
      let count = Int(Wire.read(p,0,4))
      guard count > 0, count <= 32, p.count == 4 + 32 * count else { return }
      var next: InlineArray<32,PowerSourceSample> = .init(repeating: .mains)
      for i in 0..<count {
        guard let sample = PowerSourceSample(UnsafeRawBufferPointer(rebasing: p[(4+i*32)..<(36+i*32)])) else { return }
        for j in 0..<i where next[j].id == sample.id { return }
        next[i] = sample
      }
      sources = next; sourceCount = count
    case PowerKind.environment:
      guard p.count == 8, let band = Self.thermalBand(rawValue: UInt32(Wire.read(p,0,4))),
        Wire.read(p,4,4) <= 1 else { return }
      thermalBand = band; lowPower = Wire.read(p,4,4) == 1
    case PowerKind.sleep, PowerKind.wake:
      guard p.isEmpty else { return }
      latestTimestamp = frame.timestampNs
      onSystemEvent?(frame.kind == PowerKind.sleep ? .sleep : .wake, frame.timestampNs)
      return
    default: return
    }
    latestTimestamp = frame.timestampNs
    publish(timestamp: frame.timestampNs)
  }
  private func publish(timestamp: UInt64) {
    var selected: PowerSourceSample?
    var external: UInt32 = 0
    for i in 0..<sourceCount {
      let s = sources[i]
      guard s.isPresent else { continue }
      if s.online { external = 4 }
      if s.kind == .battery, selected?.kind != .battery { selected = s }
      else if s.kind == .ups, selected == nil { selected = s }
    }
    let state: UInt32
    if let s = selected { state = s.charging ? 2 : s.full ? 3 : s.online ? 4 : 1 }
    else { state = 0 }
    guard let sample = PowerSample(percent: selected?.percent ?? .max, state: state, external: external,
      thermal: thermalBand, lowPower: lowPower, timeToEmpty: selected?.timeToEmpty ?? 0,
      timeToFull: selected?.timeToFull ?? 0, drawMilliwatts: 0, cpuThrottle: 0, gpuThrottle: 0, updated: timestamp) else { return }
    let callback = onPublished
    _ = writer.publish(sample) { callback?() }
  }
}
