import TarwinLoader

/// Validate the installed debug SDK before borrowing its contract. Use the
/// same independently pinned system enrollment and immutable policy for W1.
/// The SDK, receipt, pin and scratch must be disjoint. No mapping authority.
public func withProvisionedDebugW1SDK<R>(
  _ sdk: UnsafeRawBufferPointer, receipt: UnsafeRawBufferPointer,
  systemEnrollment: UnsafeRawBufferPointer, policy: W0Policy,
  hashes: UnsafeMutableBufferPointer<BlakeCv>, polynomials: UnsafeMutableBufferPointer<Int32>,
  message: UnsafeMutableRawBufferPointer, _ body: (EarlyRIDLContract) -> R
) -> R? {
  guard policy.debugEmulator, policy.train == (26, 11, 1), policy.tir == (26, 11, 2),
    let utc = policy.trustedUTC, validPin(systemEnrollment, utc: utc),
    hashes.count >= 54, polynomials.count >= 2048,
    let n = debugW1SDKMessage(sdk, machine: policy.machine, into: message),
    authenticated(receipt, systemEnrollment, .init(rebasing: UnsafeRawBufferPointer(message)[..<n]),
      hashes, polynomials)
  else { return nil }
  return withW1SDKContract(sdk, body)
}
