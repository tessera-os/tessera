import TarwinLoader

/// Checks both TSG1 signatures against independently trusted keys; grants no identity or execution authority.
public func verifyHybridSignature(
  message: UnsafeRawBufferPointer, envelope: UnsafeRawBufferPointer,
  ed25519Key: UnsafeRawBufferPointer, mldsa65Key: UnsafeRawBufferPointer,
  work: UnsafeMutableBufferPointer<Int32>
) -> Bool {
  guard let signature = HybridEnvelope(envelope, descriptor: 0..<envelope.count) else { return false }
  return verifyEd25519(
    key: ed25519Key, message: message,
    signature: .init(rebasing: envelope[signature.ed25519]))
    && verifyMLDSA65(
      key: mldsa65Key, message: message, context: .init(start: nil, count: 0),
      signature: .init(rebasing: envelope[signature.mldsa65]), work: work)
}
