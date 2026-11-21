import TarwinABI

/// Train-private register transport. No pointer is retained past entry.
public enum NativePorts {
  public static func create<G: NativeGate>(gate: inout G) -> CallResult {
    gate.enter(number: TarwinCall.portCreate, registers: CallRegisters())
  }
  /// Eight little-endian words in the public 64-byte Completion layout.
  /// The kernel replaces kind and timestamp.
  public static func post<G: NativeGate>(
    _ port: UInt64, packet: UnsafeBufferPointer<UInt64>, gate: inout G
  ) -> CallResult {
    guard packet.count == 8 else { return CallResult(status: 1) }
    return gate.enter(
      number: TarwinCall.portPost,
      registers: CallRegisters(port, UInt64(UInt(bitPattern: packet.baseAddress))))
  }
  public static func cancel<G: NativeGate>(_ port: UInt64, key: UInt64, gate: inout G) -> CallResult
  {
    gate.enter(number: TarwinCall.portCancel, registers: CallRegisters(port, key))
  }
}
