import TarwinLoader
import TarwinRandomCore

public enum KernelEntropyPolicy { case certified, debugQEMU }
public enum CheckedEntropySource { case physicalHardware, emulatedTPM, uncredited }

/// Access only under the kernel RNG lock. Generation and source provenance
/// come from protected platform state, never userspace or a boot-set member.
public struct KernelRandom: ~Copyable {
  /// An independent post-boot sample is due before this many output blocks.
  public static let blocksPerSample = 32_768
  public private(set) var remainingBlocks = blocksPerSample
  private var stream: ChaChaStream
  private let policy: KernelEntropyPolicy
  private let bootEpoch: RandomEpoch
  private var epoch: RandomEpoch?

  private static func accepts(
    _ mode: KernelEntropyPolicy, _ source: CheckedEntropySource, _ gen: RandomEpoch?
  ) -> Bool {
    guard let gen, gen.available else { return false }
    switch mode {
    case .certified:
      if case .fixedDebugQEMU = gen { return false }
      return source == .physicalHardware
    case .debugQEMU:
      guard gen != .physical else { return false }
      return source == .emulatedTPM || source == .physicalHardware
    }
  }
  // Encode generation and environment separately from the fixed-size secret
  // inputs. Context separation prevents a reseed transcript acting as a boot seed.
  private static func suffix(
    _ dst: UnsafeMutableRawBufferPointer, _ gen: RandomEpoch, _ policy: KernelEntropyPolicy
  ) {
    dst[0] = policy == .certified ? 1 : 2
    switch gen {
    case .physical: dst[1] = 0
    case .virtualMachine: dst[1] = 1
    case .fixedDebugQEMU: dst[1] = 2
    }
    let (lo, hi) = gen.wireWords
    for i in 0..<8 {
      dst[2 + i] = UInt8(truncatingIfNeeded: lo >> (8 * i))
      dst[10 + i] = UInt8(truncatingIfNeeded: hi >> (8 * i))
    }
  }
  private static func words(_ c: BlakeCv) -> InlineArray<8, UInt32> {
    [c.w0, c.w1, c.w2, c.w3, c.w4, c.w5, c.w6, c.w7]
  }
  public init?(
    policy: KernelEntropyPolicy, bootSeed: UnsafeRawBufferPointer,
    hardware: UnsafeRawBufferPointer, source: CheckedEntropySource, generation: RandomEpoch?
  ) {
    guard let generation else { return nil }
    if case .fixedDebugQEMU = generation { return nil }
    self.init(policy: policy, bootSeed: bootSeed, hardware: hardware, source: source,
      validated: generation)
  }

  init?(
    policy: KernelEntropyPolicy, bootSeed: UnsafeRawBufferPointer,
    hardware: UnsafeRawBufferPointer, source: CheckedEntropySource, validated generation: RandomEpoch
  ) {
    guard Self.accepts(policy, source, generation), bootSeed.count == 64,
      hardware.count == 32
    else { return nil }
    var input = InlineArray<114, UInt8>(repeating: 0)
    let cv = withUnsafeMutableBytes(of: &input) { buf in
      for i in 0..<64 { buf[i] = bootSeed[i] }
      for i in 0..<32 { buf[64 + i] = hardware[i] }
      Self.suffix(.init(rebasing: buf[96...]), generation, policy)
      return deriveSmallBlakeKey(context: "Tarwin 1.0 kernel random boot", material: .init(buf))
    }
    guard let cv else { return nil }
    stream = ChaChaStream(keyWords: Self.words(cv))
    self.policy = policy
    bootEpoch = generation
    epoch = generation
  }

  /// Feed each fresh checked sample from the platform's continuing entropy
  /// service. On restore require a fresh sample before producing a single byte.
  public mutating func reseed(
    hardware: UnsafeRawBufferPointer, source: CheckedEntropySource, generation: RandomEpoch?
  ) -> Bool {
    let previous = epoch
    epoch = nil
    guard let generation,
      Self.accepts(policy, source, generation), hardware.count == 32
    else {
      return false
    }
    switch (bootEpoch, generation) {
    case (.physical, .physical), (.virtualMachine, .virtualMachine): break
    case (.fixedDebugQEMU, .fixedDebugQEMU):
      // A changed or lost fixed ID contradicts the launch contract. Boot again.
      guard previous == bootEpoch, generation == bootEpoch else { return false }
    default: return false
    }
    var input = InlineArray<82, UInt8>(repeating: 0)
    let cv = withUnsafeMutableBytes(of: &input) { buf in
      stream.fill(.init(rebasing: buf[..<32]))
      for i in 0..<32 { buf[32 + i] = hardware[i] }
      Self.suffix(.init(rebasing: buf[64...]), generation, policy)
      return deriveSmallBlakeKey(context: "Tarwin 1.0 kernel random reseed", material: .init(buf))
    }
    guard let cv else {
      epoch = nil
      return false
    }
    stream = ChaChaStream(keyWords: Self.words(cv))
    epoch = generation
    remainingBlocks = Self.blocksPerSample
    return true
  }
  public mutating func fill(_ output: UnsafeMutableRawBufferPointer, generation: RandomEpoch?)
    -> Bool
  {
    guard let generation, generation == epoch else {
      epoch = nil
      return false
    }
    let blocks = output.count / 32 + (output.count % 32 == 0 ? 0 : 1)
    guard blocks <= remainingBlocks else { return false }
    remainingBlocks -= blocks
    stream.fill(output)
    return true
  }
  public mutating func word(generation: RandomEpoch?) -> UInt64? {
    var result: UInt64 = 0
    let ok = withUnsafeMutableBytes(of: &result) { fill($0, generation: generation) }
    return ok ? UInt64(littleEndian: result) : nil
  }
}
