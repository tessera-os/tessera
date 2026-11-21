#if TARWIN_NON_RESTORABLE_DEBUG && hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
import Tarboot
import TarwinBoot
import TarwinDevice
import TarwinKernelRandom
import TarwinLoader
import TarwinW0Verify

public struct W1ColdVerifiedSet {
  public let set: W1BootSet
  public let archive: UnsafeRawBufferPointer
  let boot: BootInfo
}

/// Construct on the sole boot CPU, at physical entry, with the original
/// loader reservation in x0. Neither the EFI verdict nor an ELF member
/// chooses this code path. Control pages must stay pinned and inaccessible
/// to devices and to the new address space even after this check.
public struct W1ColdKernelIntake {
  public let layout: ColdKernelLayout
  public let block, map: UnsafeRawBufferPointer

  @unsafe public init?(handoff: UInt64) {
    guard let k = ColdKernelLayout(handoff: handoff) else { return nil }
    var held: InlineArray<2, DeviceRange> = [
      .init(base: k.handoff, length: k.table - k.handoff),
      .init(base: k.signature, length: k.end - k.signature),
    ]
    var bus = ColdBus(layout: .lowOnly)
    guard withUnsafeBytes(of: &held, {
      checkVirtBootDMAContinuity(table: k.table, commands: k.commands,
        protected: $0.bindMemory(to: DeviceRange.self), bus: &bus)
    }) == .matchesColdFence else { return nil }
    layout = k
    let p = UnsafeRawPointer(bitPattern: UInt(k.handoff))!
    block = .init(start: p, count: 4096)
    map = .init(start: p + 4096, count: ColdKernelLayout.mapBytes)
  }

  /// Only the measured kernel's independently protected installation
  /// provides pins, contract and policy. Re-read the signature using PIO;
  /// never follow an unchecked archive pointer into an MMIO aperture.
  @unsafe public func verify(launch: borrowing FixedDebugRandomLaunch,
    enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer,
    policy: W0Policy, contract: EarlyRIDLContract) -> W1BootSet? {
    snapshot(launch: launch, enrollment: enrollment, systemEnrollment: systemEnrollment,
      policy: policy, contract: contract)?.set
  }

  @unsafe public func snapshot(launch: borrowing FixedDebugRandomLaunch,
    enrollment: UnsafeRawBufferPointer, systemEnrollment: UnsafeRawBufferPointer,
    policy: W0Policy, contract: EarlyRIDLContract) -> W1ColdVerifiedSet? {
    guard let profile = W1HandoffProfile(nonRestorable: launch),
      let b = profile.decode(block, at: layout.handoff, map: map, at: layout.handoff + 4096),
      layout.containsSeparateArchive(b.bootSet, bytes: b.bootSetSize),
      b.security == 2, b.slot == 0, coversWorkspace(b.mapCount)
    else { return nil }
    let archive = UnsafeRawBufferPointer(start: UnsafeRawPointer(bitPattern: UInt(b.bootSet)), count: Int(b.bootSetSize))
    let output = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(layout.signature)), count: 65536)
    let work = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(layout.scratch)), count: 16384)
    var cfg = QEMUVirtConfig(mapped: UnsafeRawPointer(bitPattern: 0x0902_0000)!)
    guard let set = QEMUW1Evidence.verifyAfterExclusion(block: block, at: layout.handoff, map: map, at: layout.handoff + 4096,
      archive: archive, at: b.bootSet, reader: &cfg, into: output, enrollment: enrollment,
      systemEnrollment: systemEnrollment, policy: policy, contract: contract, scratch: work, handoff: profile)
    else { return nil }
    return W1ColdVerifiedSet(set: set, archive: archive, boot: b)
  }

  private func coversWorkspace(_ count: UInt64) -> Bool {
    for i in 0..<Int(count) {
      let at = 32 * i
      if map.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian == layout.handoff {
        return map.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self).littleEndian == layout.end - layout.handoff
          && map.loadUnaligned(fromByteOffset: at + 16, as: UInt32.self).littleEndian == 8
      }
    }
    return false
  }
}
#endif
