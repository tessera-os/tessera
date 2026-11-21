import TarwinDevice

/// A registry node that looks like the S23+ GPU. Matching is discovery only:
/// it grants no MMIO, DMA, interrupt or command access.
public struct AdrenoCandidate: Equatable, @unchecked Sendable {
  public let chipID: UInt64
  public let registers: DeviceRange
  public let interrupts: UInt16
}

public enum AdrenoDiscovery {
  /// Adreno 740 in the Galaxy S23+ (SM8550, dm2q).
  public static let adreno740: UInt64 = 0x4305_0a01
  /// Every register the provider touches lies below this many bytes.
  static let registerBytes = UInt64(AdrenoRegister.highest + 1) * 4

  public static func match(_ device: HardwareDevice) -> AdrenoCandidate? {
    guard device.identity == adreno740, device.wiredInterrupts > 0,
      let registers = device.mmio.first(where: { !$0.frameBuffer })?.range,
      registers.valid(), registers.length >= registerBytes
    else { return nil }
    return AdrenoCandidate(
      chipID: device.identity, registers: registers, interrupts: device.wiredInterrupts)
  }
}

/// What a trusted platform profile proves before the GPU may be opened: the
/// requester and its IOMMU domain, narrowly scoped register and DMA grants,
/// checked queue/command isolation, and drain/revocation on that hardware.
/// Firmware, power and GMU bring-up also belong to the profile. Only this
/// module can create one, and no hardware-verified profile exists yet.
public struct AdrenoProfile: @unchecked Sendable {
  public let chipID: UInt64
  public let domain: UInt64
  public let gpuAddresses: DeviceRange
  public let page: UInt64
  public let ringBytes: UInt32
  public let counterHz: UInt64?

  init(
    chipID: UInt64, domain: UInt64, gpuAddresses: DeviceRange, page: UInt64, ringBytes: UInt32,
    counterHz: UInt64?
  ) {
    self.chipID = chipID
    self.domain = domain
    self.gpuAddresses = gpuAddresses
    self.page = page
    self.ringBytes = ringBytes
    self.counterHz = counterHz
  }
}

enum AdrenoTrustedProfiles {
  static func admit(_ candidate: AdrenoCandidate) -> AdrenoProfile? { nil }
}

public enum AdrenoOpenRefusal: Equatable, Sendable {
  case notAdreno740
  /// Matched, but no trusted platform profile admits this device.
  case notAdmitted
}

public enum AdrenoOpenResult {
  case opened(AdrenoGPUProvider)
  case unavailable(AdrenoOpenRefusal)
}

public enum AdrenoGPUOpener {
  /// The production opener. It touches the platform only after admission,
  /// so today every device, matching or not, is reported unavailable.
  public static func open(_ device: HardwareDevice, platform: any AdrenoPlatform) -> AdrenoOpenResult {
    guard let candidate = AdrenoDiscovery.match(device) else { return .unavailable(.notAdreno740) }
    guard let profile = AdrenoTrustedProfiles.admit(candidate) else {
      return .unavailable(.notAdmitted)
    }
    do {
      return .opened(try AdrenoGPUProvider(candidate: candidate, profile: profile, platform: platform))
    } catch {
      return .unavailable(.notAdmitted)
    }
  }
}
