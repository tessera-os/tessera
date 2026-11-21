import TarwinABI

/// Private train-matched register ABI. Counts in first/second are valid
/// only on success; peek never dequeues the message.
public enum NativeChannels {
  public static func write<G: NativeGate>(
    _ name: UInt64, bytes: UnsafeRawBufferPointer, names: UnsafeBufferPointer<UInt64>, gate: inout G
  ) -> CallResult {
    gate.enter(
      number: TarwinCall.channelWrite,
      registers: CallRegisters(
        name, UInt64(UInt(bitPattern: bytes.baseAddress)), UInt64(bytes.count),
        UInt64(UInt(bitPattern: names.baseAddress)), UInt64(names.count)))
  }
  public static func peek<G: NativeGate>(_ name: UInt64, gate: inout G) -> CallResult {
    gate.enter(number: TarwinCall.channelPeek, registers: CallRegisters(name))
  }
  public static func read<G: NativeGate>(
    _ name: UInt64, into bytes: UnsafeMutableRawBufferPointer,
    names: UnsafeMutableBufferPointer<UInt64>, gate: inout G
  ) -> CallResult {
    gate.enter(
      number: TarwinCall.channelRead,
      registers: CallRegisters(
        name, UInt64(UInt(bitPattern: bytes.baseAddress)), UInt64(bytes.count),
        UInt64(UInt(bitPattern: names.baseAddress)), UInt64(names.count)))
  }
}
