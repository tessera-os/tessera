/// Trusted, ordered device accesses on the fixed QEMU virt-11.1 cold diagnostic.
/// A failed access must not be reported as a successful zero or absent function.
public protocol ColdVirtRegisters: ~Copyable {
  mutating func read32(_ physical: UInt64) -> UInt32?
  mutating func write32(_ physical: UInt64, _ value: UInt32) -> Bool
  mutating func fwConfigWord(_ selector: UInt16) -> UInt32?
}

/// None of these results authorize first entry. In particular the SMMU
/// acknowledgement is not a device drain, proof of a cold start or a DMA lease.
public enum ColdVirtPCIResult: Equatable {
  case unsupportedPlatform, unexpectedPCI, busMasterActive, smmuInUse, updateFailed
  case pciAbortAcknowledged
}

/// Only for the pinned, single-CPU TCG fixture, with hotplug and restore
/// excluded externally. Never take over a running SMMU or disable translation.
func coldVirtInventory<R: ColdVirtRegisters & ~Copyable>(
  _ r: inout R, firmwareEndpoints: Bool
) -> ColdVirtPCIResult? {
  // fw_cfg words here are decoded little endian from the four data bytes.
  guard r.fwConfigWord(0) == 0x554d_4551, r.fwConfigWord(1) == 1,
    let pid = r.read32(0x0800_ffe8), pid >> 4 & 15 == 3,
    // msi=off omits the ITS but the redistributor still advertises LPIs.
    // One last redistributor, disabled LPIs, no pending register writes.
    r.read32(0x080a_0008) == 0x0100_0011, r.read32(0x080a_0000) == 2
  else { return .unsupportedPlatform }
  for n in 0..<32 {
    let base = UInt64(0x0a00_0000 + n * 0x200)
    guard r.read32(base) == 0x7472_6976, r.read32(base + 8) == 0 else {
      return .unsupportedPlatform
    }
  }
  // One flat bus with GPEX, modern virtio-blk and modern virtio-rng.
  // Both endpoints must have iommu_platform=on in the trusted launch.
  for fn in 0..<256 {
    let base = 0x40_1000_0000 + UInt64(fn) * 4096
    let expected: UInt32 =
      switch fn {
      case 0: 0x0008_1b36
      case 8: 0x1042_1af4
      case 16: 0x1044_1af4
      default: .max
      }
    guard r.read32(base) == expected else { return .unexpectedPCI }
    if expected != .max && (!firmwareEndpoints || fn == 0) {
      guard let cmd = r.read32(base + 4), cmd & 4 == 0 else { return .busMasterActive }
    }
  }
  return nil
}

private func coldVirtSmmuIdle<R: ColdVirtRegisters & ~Copyable>(_ r: inout R) -> Bool {
  let smmu: UInt64 = 0x0905_0000
  return r.read32(smmu + 0x20) == 0 && r.read32(smmu + 0x24) == 0
    && r.read32(smmu + 0x50) == 0 && r.read32(smmu + 0x54) == 0
    && r.read32(smmu + 0x60) == 0 && r.read32(smmu + 0x64) == 0
}

func coldVirtSmmuCheck<R: ColdVirtRegisters & ~Copyable>(_ r: inout R) -> ColdVirtPCIResult? {
  let smmu: UInt64 = 0x0905_0000
  guard r.read32(smmu + 0xfe0) == 0x84, r.read32(smmu + 0xfe4) == 0xb4,
    r.read32(smmu + 0xff0) == 0x0d, r.read32(smmu + 0xff4) == 0xf0,
    r.read32(smmu + 0xff8) == 0x05, r.read32(smmu + 0xffc) == 0xb1
  else { return .unsupportedPlatform }
  return coldVirtSmmuIdle(&r) ? nil : .smmuInUse
}

public func requestColdVirtPCIAbort<R: ColdVirtRegisters & ~Copyable>(
  registers r: inout R
) -> ColdVirtPCIResult {
  if let error = coldVirtInventory(&r, firmwareEndpoints: false) ?? coldVirtSmmuCheck(&r) {
    return error
  }
  // Keep the reset bypass attributes; request ABORT before any device start.
  let gbpa: UInt64 = 0x0905_0044
  guard let previous = r.read32(gbpa), previous == 0x1000 || previous == 0x10_1000 else {
    return .smmuInUse
  }
  if previous == 0x1000 && !r.write32(gbpa, 0x8010_1000) { return .updateFailed }
  for _ in 0..<256 {
    guard let value = r.read32(gbpa) else { return .updateFailed }
    if value & 0x8000_0000 == 0 {
      guard value == 0x10_1000, coldVirtSmmuIdle(&r) else { return .updateFailed }
      return .pciAbortAcknowledged
    }
  }
  return .updateFailed
}
