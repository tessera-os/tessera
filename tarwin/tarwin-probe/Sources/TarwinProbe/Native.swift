import TarwinSyscall

// User arguments have been copied, and resource/hook tokens resolved by kernel
// authority. Authentication must inspect exactly the immutable object it pins.
public func attachProbe(
  _ call: UInt64, _ attachment: inout ProbeAttachment, _ resource: Bool,
  _ module: UInt64, _ hook: UInt64, _ verifyAndPin: (UInt64, UInt64) -> UInt64,
  _ publish: (UInt64, UInt64) -> Bool, _ unpin: (UInt64) -> Void
) -> Bool {
  if call != TarwinCall.probeAttach { return false }
  return attachment.attach(resource, module, hook, verifyAndPin, publish, unpin)
}
