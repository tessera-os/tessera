import TarwinBoot
import TarwinRandomCore

/// Caller owns protected, stable mappings. Policy and host capabilities must
/// come from the trusted launcher, never from the TBIB or other guest bytes.
public struct FixedDebugRandomLaunch: ~Copyable {
  public var random: KernelRandom
  public let generation: RandomEpoch

  public init?(
    policy: KernelEntropyPolicy, allowsMigration: Bool, allowsSnapshots: Bool,
    block: UnsafeRawBufferPointer, at blockAddress: UInt64,
    map: UnsafeRawBufferPointer, at mapAddress: UInt64,
    hardware: UnsafeRawBufferPointer, source: CheckedEntropySource
  ) {
    guard policy == .debugQEMU, !allowsMigration, !allowsSnapshots,
      let decoded = readFixedDebugQEMUHandoff(block: block, at: blockAddress, map: map, at: mapAddress)
    else { return nil }
    let id = RandomEpoch.fixedDebugQEMU(low: decoded.generation.low, high: decoded.generation.high)
    guard let generator = KernelRandom(policy: policy, bootSeed: .init(rebasing: block[96..<160]),
      hardware: hardware, source: source, validated: id) else { return nil }
    random = consume generator
    generation = id
  }
}
