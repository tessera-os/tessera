public enum SigningRole {
  case release
  case device
  case developer
  case enrolledPlatform
}

public enum ImagePurpose {
  case bootSet
  case system
  case framework
  case application
  case driver
  case finalized
  case probe
  case dynamicCode
}

// Policy after certificate and signature verification. This does not
// authenticate a key, inspect a certificate, or mark a page as executable.
public func signerPermitted(
  _ role: SigningRole, _ purpose: ImagePurpose,
  _ certified: Bool, _ developerMode: Bool, _ localDevice: Bool,
  _ certificateDays: UInt32, _ revoked: Bool
) -> Bool {
  if revoked { return false }
  return switch role {
  case .release:
    purpose == .bootSet || purpose == .system || purpose == .framework || purpose == .application
      || purpose == .driver
  case .device:
    localDevice && (purpose == .finalized || purpose == .probe || purpose == .dynamicCode)
  case .developer:
    developerMode && certificateDays > 0 && certificateDays <= 182
      && (purpose == .application || purpose == .driver || purpose == .framework)
  case .enrolledPlatform: !certified && (purpose == .bootSet || purpose == .system)
  }
}

public func processEntitlements(_ signedMask: UInt64, _ jobCeiling: UInt64) -> UInt64 {
  return signedMask & jobCeiling
}
