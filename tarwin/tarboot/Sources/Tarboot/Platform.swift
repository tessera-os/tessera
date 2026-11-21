// Admission of normalized facts discovered by firmware. Missing discovery
// results must not be reported as a supported version or capability.
public struct PlatformFacts {
  public var mobile: Bool
  public var uefi: Bool
  public var verified: Bool
  public var firmwareMajor: UInt16
  public var firmwareMinor: UInt16
  public var tableMajor: UInt16
  public var tableMinor: UInt16
  public var iommuCoversAll: Bool
  public var protectedRoot: Bool
  public var monotonicCounter: Bool
  public var sealedStorage: Bool
  public var entropySource: Bool
  public var memoryBytes: UInt64
  public var storageBytes: UInt64
  public var nvme: Bool
  public var storageMajor: UInt16
  public var storageMinor: UInt16

  public init(
    mobile: Bool, uefi: Bool, verified: Bool, firmwareMajor: UInt16, firmwareMinor: UInt16,
    tableMajor: UInt16, tableMinor: UInt16, iommuCoversAll: Bool, protectedRoot: Bool,
    monotonicCounter: Bool, sealedStorage: Bool, entropySource: Bool, memoryBytes: UInt64,
    storageBytes: UInt64, nvme: Bool, storageMajor: UInt16, storageMinor: UInt16
  ) {
    self.mobile = mobile
    self.uefi = uefi
    self.verified = verified
    self.firmwareMajor = firmwareMajor
    self.firmwareMinor = firmwareMinor
    self.tableMajor = tableMajor
    self.tableMinor = tableMinor
    self.iommuCoversAll = iommuCoversAll
    self.protectedRoot = protectedRoot
    self.monotonicCounter = monotonicCounter
    self.sealedStorage = sealedStorage
    self.entropySource = entropySource
    self.memoryBytes = memoryBytes
    self.storageBytes = storageBytes
    self.nvme = nvme
    self.storageMajor = storageMajor
    self.storageMinor = storageMinor
  }
}

func atLeast(_ major: UInt16, minor: UInt16, needMajor: UInt16, needMinor: UInt16) -> Bool {
  return major > needMajor || (major == needMajor && minor >= needMinor)
}

public func admitsPlatform(_ facts: PlatformFacts) -> Bool {
  if !facts.verified || !facts.iommuCoversAll || !facts.protectedRoot || !facts.monotonicCounter
    || !facts.sealedStorage || !facts.entropySource
  {
    return false
  }
  if facts.uefi {
    if !atLeast(facts.firmwareMajor, minor: facts.firmwareMinor, needMajor: 2, needMinor: 9)
      || !atLeast(facts.tableMajor, minor: facts.tableMinor, needMajor: 6, needMinor: 4)
    {
      return false
    }
  } else if !facts.mobile
    || !atLeast(facts.tableMajor, minor: facts.tableMinor, needMajor: 0, needMinor: 4)
  {
    return false
  }
  let minimum: UInt64 = facts.mobile ? 8_589_934_592 : 17_179_869_184
  if facts.memoryBytes < minimum || facts.memoryBytes > (UInt64(1) << 52)
    || facts.storageBytes < 256_000_000_000
  {
    return false
  }
  if facts.nvme {
    return atLeast(facts.storageMajor, minor: facts.storageMinor, needMajor: 1, needMinor: 4)
  }
  return atLeast(facts.storageMajor, minor: facts.storageMinor, needMajor: 4, needMinor: 0)
}

public struct CpuIntersection {
  public var count: UInt32
  public var common: UInt64
  public var refused: Bool

  public init(count: UInt32, common: UInt64, refused: Bool) {
    self.count = count
    self.common = common
    self.refused = refused
  }
}

public func addProcessor(_ state: inout CpuIntersection, mandatory: Bool, optional: UInt64) -> Bool
{
  if !mandatory || state.count >= 4096 || state.refused {
    state.refused = true
    return false
  }
  state.common = state.count == 0 ? optional : state.common & optional
  state.count += 1
  return true
}
