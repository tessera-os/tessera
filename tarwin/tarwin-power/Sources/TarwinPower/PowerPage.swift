import Synchronization

public struct PowerSample: Equatable {
  public let percent: UInt32, state: UInt32, external: UInt32, thermal: ThermalBand, lowPower: Bool
  public let timeToEmpty: UInt64, timeToFull: UInt64, drawMilliwatts: UInt32, cpuThrottle: UInt32,
    gpuThrottle: UInt32, updated: UInt64
  public init?(
    percent: UInt32, state: UInt32, external: UInt32, thermal: ThermalBand, lowPower: Bool,
    timeToEmpty: UInt64, timeToFull: UInt64, drawMilliwatts: UInt32, cpuThrottle: UInt32,
    gpuThrottle: UInt32, updated: UInt64
  ) {
    guard percent <= 100 || percent == .max, state <= 4, external <= 4, cpuThrottle <= 100,
      gpuThrottle <= 100
    else { return nil }
    self.percent = percent
    self.state = state
    self.external = external
    self.thermal = thermal
    self.lowPower = lowPower
    self.timeToEmpty = timeToEmpty
    self.timeToFull = timeToFull
    self.drawMilliwatts = drawMilliwatts
    self.cpuThrottle = cpuThrottle
    self.gpuThrottle = gpuThrottle
    self.updated = updated
  }
}
private func pair(_ lo: UInt32, _ hi: UInt32) -> UInt64 { UInt64(lo) | UInt64(hi) << 32 }
/// One serialized writer for a fresh, pinned, coherent 4096-byte ABI page.
/// Initialize before giving clients read-only (never writable) mappings.
/// All words are atomic; a slow reader cannot hold up the producer.
public struct PowerPageWriter: ~Copyable {
  private let words: UnsafeMutablePointer<Atomic<UInt64>>
  public init?(initializing memory: UnsafeMutableRawBufferPointer) {
    guard memory.count == 4096, let base = memory.baseAddress, UInt(bitPattern: base) & 4095 == 0,
      MemoryLayout<Atomic<UInt64>>.stride == 8
    else { return nil }
    memory.initializeMemory(as: UInt8.self, repeating: 0)
    words = base.bindMemory(to: Atomic<UInt64>.self, capacity: 9)
    for i in 0..<9 { words.advanced(by: i).initialize(to: Atomic(0)) }
  }
  public mutating func publish(_ s: PowerSample, notify: () -> Void) -> Bool {
    let seq = words[8].load(ordering: .sequentiallyConsistent)
    guard seq & 1 == 0, seq <= UInt64.max - 2,
      s.updated >= words[7].load(ordering: .sequentiallyConsistent)
    else { return false }
    let level: UInt32
    switch s.thermal {
    case .nominal: level = 0
    case .fair: level = 1
    case .serious: level = 2
    case .critical: level = 3
    }
    words[8].store(seq + 1, ordering: .sequentiallyConsistent)
    words[0].store(pair(s.percent, s.state), ordering: .sequentiallyConsistent)
    words[1].store(pair(s.external, level), ordering: .sequentiallyConsistent)
    words[2].store(s.lowPower ? 1 : 0, ordering: .sequentiallyConsistent)
    words[3].store(s.timeToEmpty, ordering: .sequentiallyConsistent)
    words[4].store(s.timeToFull, ordering: .sequentiallyConsistent)
    words[5].store(pair(s.drawMilliwatts, s.cpuThrottle), ordering: .sequentiallyConsistent)
    words[6].store(UInt64(s.gpuThrottle), ordering: .sequentiallyConsistent)
    words[7].store(s.updated, ordering: .sequentiallyConsistent)
    words[8].store(seq + 2, ordering: .sequentiallyConsistent)
    notify()
    return true
  }
}
/// The owner pins the mapping throughout this read. Match the ABI reader's
/// eight retries rather than spinning forever if refresh is interrupted.
public func readPowerPage(_ page: UnsafeRawBufferPointer) -> PowerSample? {
  guard page.count == 4096, let base = page.baseAddress, UInt(bitPattern: base) & 4095 == 0,
    MemoryLayout<Atomic<UInt64>>.stride == 8
  else { return nil }
  let w = base.assumingMemoryBound(to: Atomic<UInt64>.self)
  func load(_ i: Int) -> UInt64 { w[i].load(ordering: .sequentiallyConsistent) }
  for _ in 0..<8 {
    let seq = load(8)
    guard seq != 0, seq & 1 == 0 else { continue }
    let a = load(0)
    let b = load(1)
    let mode = load(2)
    let empty = load(3)
    let full = load(4)
    let rates = load(5)
    let gpu = load(6)
    let now = load(7)
    guard load(8) == seq else { continue }
    guard mode <= 1, gpu <= 100 else { return nil }
    let band: ThermalBand
    switch b >> 32 {
    case 0: band = .nominal
    case 1: band = .fair
    case 2: band = .serious
    case 3: band = .critical
    default: return nil
    }
    return PowerSample(
      percent: UInt32(truncatingIfNeeded: a), state: UInt32(a >> 32),
      external: UInt32(truncatingIfNeeded: b), thermal: band, lowPower: mode == 1,
      timeToEmpty: empty, timeToFull: full, drawMilliwatts: UInt32(truncatingIfNeeded: rates),
      cpuThrottle: UInt32(rates >> 32), gpuThrottle: UInt32(gpu), updated: now)
  }
  return nil
}
