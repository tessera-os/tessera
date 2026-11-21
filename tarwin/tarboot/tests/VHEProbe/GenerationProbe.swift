import Tarboot
import TarwinArchAarch64
import TarwinRandomCore
import TarwinW1Generation

@_extern(c, "tarwin_mmio_read64") private func load(_ address: UnsafeRawPointer) -> UInt64

private let high: UInt64 = 0xffff_8000_4100_0000
private struct Witness { let mapping: W1KernelGeneration; let initial: RandomEpoch }

private func identityRead(_ physical: UInt64) -> UInt64? {
  let base = W1GenerationSource.registerBase
  guard physical >= base, physical - base < 32, physical & 7 == 0 else { return nil }
  return load(UnsafeRawPointer(bitPattern: UInt(physical))!)
}

func installGeneration(in root: inout ArmKernelTranslation, context: UInt64) -> UInt32 {
  let base = W1GenerationSource.registerBase
  var config = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
  var probed = false
  guard let source = W1GenerationSource(policy: .readOnlyVirt11, reader: &config,
    regions: .init(start: nil, count: 0), readWord: { address in
      probed = true
      return identityRead(address)
    }) else {
    if !probed, case .unavailable = qemuGenerationDevice(&config) { return 6 }
    return 1
  }
  guard let epoch = source.current(readWord: identityRead),
    let mapping = W1KernelGeneration(source, at: high, in: &root),
    mapping.readWord(base) == nil else { return 1 }
  UnsafeMutablePointer<Witness>(bitPattern: UInt(context + 2048))!.initialize(
    to: Witness(mapping: mapping, initial: epoch))
  return 0
}

@_cdecl("tarwin_vhe_sample_generation")
public func sampleGeneration(_ context: UInt64) -> UInt32 {
  let witness = UnsafePointer<Witness>(bitPattern: UInt(context + 2048))!.pointee
  let mapped = witness.mapping, pa = W1GenerationSource.registerBase
  guard mapped.readWord(pa + 1) == nil, mapped.readWord(pa + 32) == nil,
    mapped.readWord(pa) == 0x3144_4947_4d56_5754 else { return 0 }
  let roots = UnsafePointer<ProbeRoots>(bitPattern: UInt(context + 128))!
  return mapped.current(in: roots.pointee.host) == witness.initial ? 1 : 0
}
