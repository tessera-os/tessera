import Darwin
import HostedDeviceWire

public enum PCMFormat: UInt32, Sendable { case f32 = 1, i16 = 2 }

public struct AudioConfiguration: Equatable, Sendable {
  public let sampleRate: UInt32
  public let channels: UInt32
  public let format: PCMFormat
  public init?(sampleRate: UInt32, channels: UInt32, format: PCMFormat) {
    guard [44100,48000].contains(sampleRate), (1...2).contains(channels) else { return nil }
    self.sampleRate = sampleRate; self.channels = channels; self.format = format
  }
}

public enum PCMConversion {
  public static func toFloat(_ value: Int16) -> Float { Float(value) / 32768 }
  public static func toInt16(_ value: Float) -> Int16 {
    guard value.isFinite else { return 0 }
    return Int16(max(-32768, min(32767, (value * 32768).rounded())))
  }
}

/// One producer and one consumer. The backing mapping must outlive this view.
public final class AudioRing: @unchecked Sendable {
  public let region: UnsafeMutableRawPointer
  public let byteCount: Int
  public let capacity: Int
  public let configuration: AudioConfiguration
  private let ownsRegion: Bool
  private let regionOwner: AnyObject?
  private let sampleBytes: Int
  public static func requiredBytes(capacity: Int, configuration: AudioConfiguration) -> Int? {
    let stride = Int(configuration.channels) * (configuration.format == .f32 ? 4 : 2)
    guard capacity > 0, capacity & (capacity - 1) == 0, capacity <= Int(UInt32.max),
      capacity <= (Int.max - 64) / stride else { return nil }
    return 64 + capacity * stride
  }
  public convenience init?(capacity: Int, configuration: AudioConfiguration) {
    guard let bytes = Self.requiredBytes(capacity: capacity, configuration: configuration) else { return nil }
    let region = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
    Self.initialize(region: region, capacity: capacity, configuration: configuration, byteCount: bytes)
    self.init(region: region, byteCount: bytes, ownsRegion: true)
  }
  public static func initialize(region: UnsafeMutableRawPointer, capacity: Int,
    configuration: AudioConfiguration, byteCount: Int) {
    precondition(UInt(bitPattern: region) % 8 == 0)
    precondition(requiredBytes(capacity: capacity, configuration: configuration).map { $0 <= byteCount } == true)
    region.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    let bytes = UnsafeMutableRawBufferPointer(start: region, count: byteCount)
    for (offset,value) in [(0,UInt32(0x52415754)),(4,UInt32(capacity)),(8,configuration.channels),
      (12,configuration.format.rawValue),(16,configuration.sampleRate)] {
      Wire.write(UInt64(value), to: bytes, at: offset, width: 4)
    }
  }
  public convenience init?(region: UnsafeMutableRawPointer, byteCount: Int) {
    self.init(region: region, byteCount: byteCount, ownsRegion: false)
  }
  convenience init?(region: UnsafeMutableRawPointer, byteCount: Int, retaining owner: AnyObject) {
    self.init(region: region, byteCount: byteCount, ownsRegion: false, regionOwner: owner)
  }
  private init?(region: UnsafeMutableRawPointer, byteCount: Int, ownsRegion: Bool, regionOwner: AnyObject? = nil) {
    guard byteCount >= 64, UInt(bitPattern: region) % 8 == 0 else { return nil }
    let bytes = UnsafeRawBufferPointer(start: region, count: byteCount)
    guard Wire.read(bytes, 0, 4) == 0x52415754,
      let format = PCMFormat(rawValue: UInt32(Wire.read(bytes, 12, 4))),
      let config = AudioConfiguration(sampleRate: UInt32(Wire.read(bytes, 16, 4)),
        channels: UInt32(Wire.read(bytes, 8, 4)), format: format),
      let needed = Self.requiredBytes(capacity: Int(Wire.read(bytes, 4, 4)), configuration: config),
      needed <= byteCount else { return nil }
    self.region = region; self.byteCount = needed; self.ownsRegion = ownsRegion
    self.regionOwner = regionOwner
    self.capacity = Int(Wire.read(bytes, 4, 4)); configuration = config
    sampleBytes = format == .f32 ? 4 : 2
    region.advanced(by: 24).bindMemory(to: Int64.self, capacity: 4)
  }
  deinit { if ownsRegion { region.deallocate() } }
  private func atomic(_ offset: Int) -> UnsafeMutablePointer<Int64> {
    region.advanced(by: offset).assumingMemoryBound(to: Int64.self)
  }
  private func load(_ offset: Int) -> UInt64 {
    UInt64(bitPattern: OSAtomicAdd64Barrier(0, atomic(offset)))
  }
  private func store(_ offset: Int, _ value: UInt64) {
    let pointer = atomic(offset)
    var old = OSAtomicAdd64Barrier(0, pointer)
    while !OSAtomicCompareAndSwap64Barrier(old, Int64(bitPattern: value), pointer) {
      old = OSAtomicAdd64Barrier(0, pointer)
    }
  }
  public var writeIndex: UInt64 { load(24) }
  public var readIndex: UInt64 { load(32) }
  public var overruns: UInt64 { load(40) }
  public var underruns: UInt64 { load(48) }
  public var availableFrames: Int { Int(min(UInt64(capacity), writeIndex &- readIndex)) }
  public var latencyNs: UInt64 { UInt64(availableFrames) * 1_000_000_000 / UInt64(configuration.sampleRate) }

  @discardableResult public func write(_ samples: UnsafeBufferPointer<Float>, frames: Int) -> Int {
    guard frames >= 0, frames <= samples.count / Int(configuration.channels) else { return 0 }
    let w = writeIndex, r = readIndex
    let used = w &- r
    guard used <= UInt64(capacity) else { return 0 }
    let count = min(frames, capacity - Int(used))
    if count < frames { OSAtomicIncrement64Barrier(atomic(40)) }
    for frame in 0..<count {
      for ch in 0..<Int(configuration.channels) {
        let offset = 64 + (Int((w &+ UInt64(frame)) & UInt64(capacity-1)) * Int(configuration.channels) + ch) * sampleBytes
        let value = samples[frame * Int(configuration.channels) + ch]
        if configuration.format == .f32 { region.storeBytes(of: value, toByteOffset: offset, as: Float.self) }
        else { region.storeBytes(of: PCMConversion.toInt16(value), toByteOffset: offset, as: Int16.self) }
      }
    }
    store(24, w &+ UInt64(count)); return count
  }
  /// Always fills the requested output; missing frames become silence.
  @discardableResult public func read(into samples: UnsafeMutableBufferPointer<Float>, frames: Int) -> Int {
    guard frames >= 0, frames <= samples.count / Int(configuration.channels) else { return 0 }
    let r = readIndex, w = writeIndex
    let available = w &- r
    let count = available <= UInt64(capacity) ? min(frames, Int(available)) : 0
    if count < frames { OSAtomicIncrement64Barrier(atomic(48)) }
    for frame in 0..<frames {
      for ch in 0..<Int(configuration.channels) {
        var value: Float = 0
        if frame < count {
          let offset = 64 + (Int((r &+ UInt64(frame)) & UInt64(capacity-1)) * Int(configuration.channels) + ch) * sampleBytes
          value = configuration.format == .f32 ? region.load(fromByteOffset: offset, as: Float.self)
            : PCMConversion.toFloat(region.load(fromByteOffset: offset, as: Int16.self))
        }
        samples[frame * Int(configuration.channels) + ch] = value
      }
    }
    store(32, r &+ UInt64(count)); return count
  }
}
