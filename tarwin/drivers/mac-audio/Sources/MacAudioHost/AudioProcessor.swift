import MacAudioWire
import Synchronization

/// The HAL and offline tests call these same allocation-free processing methods.
public final class AudioProcessor: @unchecked Sendable {
  public let ring: AudioRing
  public let running = Atomic<Bool>(false)
  public let draining = Atomic<Bool>(false)
  public let muted = Atomic<Bool>(false)
  public let gainBits = Atomic<UInt32>(Float(1).bitPattern)
  public let position = Atomic<UInt64>(0)
  public let hostTimeNs = Atomic<UInt64>(0)
  public init(ring: AudioRing) { self.ring = ring }
  @discardableResult public func render(into output: UnsafeMutableBufferPointer<Float>, frames: Int,
    timestampNs: UInt64) -> Int {
    guard frames >= 0, frames <= output.count / Int(ring.configuration.channels) else { return 0 }
    guard running.load(ordering: .acquiring) else {
      for i in 0..<frames * Int(ring.configuration.channels) { output[i] = 0 }; return 0
    }
    let count = ring.read(into: output, frames: frames)
    let gain = muted.load(ordering: .relaxed) ? 0 : Float(bitPattern: gainBits.load(ordering: .relaxed))
    for i in 0..<frames * Int(ring.configuration.channels) { output[i] *= gain }
    position.wrappingAdd(UInt64(count), ordering: .relaxed)
    hostTimeNs.store(timestampNs, ordering: .releasing)
    if draining.load(ordering: .acquiring), ring.availableFrames == 0 {
      running.store(false, ordering: .releasing)
    }
    return count
  }
  @discardableResult public func capture(_ input: UnsafeBufferPointer<Float>, frames: Int,
    timestampNs: UInt64) -> Int {
    guard running.load(ordering: .acquiring), frames >= 0,
      frames <= input.count / Int(ring.configuration.channels) else { return 0 }
    // Capture gain is applied in fixed-size stack chunks; the HAL input buffer stays borrowed.
    let channels = Int(ring.configuration.channels)
    var total = 0
    let gain = muted.load(ordering: .relaxed) ? 0 : Float(bitPattern: gainBits.load(ordering: .relaxed))
    withUnsafeTemporaryAllocation(of: Float.self, capacity: 512) { scratch in
      var offset = 0
      while offset < frames {
        let n = min(512 / channels, frames - offset)
        for i in 0..<n * channels { scratch[i] = input[offset * channels + i] * gain }
        total += ring.write(UnsafeBufferPointer(start: scratch.baseAddress, count: n * channels), frames: n)
        offset += n
      }
    }
    position.wrappingAdd(UInt64(total), ordering: .relaxed)
    hostTimeNs.store(timestampNs, ordering: .releasing); return total
  }
}
