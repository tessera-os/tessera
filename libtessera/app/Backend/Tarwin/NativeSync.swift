import TarwinABI

public enum NativeSync {
  public static func wait32<G: NativeGate>(
    _ address: UInt64, expected: UInt32, deadline: UInt64, gate: inout G
  ) -> CallResult {
    gate.enter(
      number: TarwinCall.syncWait32, registers: CallRegisters(address, UInt64(expected), deadline))
  }
  public static func wait64<G: NativeGate>(
    _ address: UInt64, expected: UInt64, deadline: UInt64, gate: inout G
  ) -> CallResult {
    gate.enter(number: TarwinCall.syncWait64, registers: CallRegisters(address, expected, deadline))
  }
  public static func wake<G: NativeGate>(_ address: UInt64, count: UInt32, gate: inout G)
    -> CallResult
  {
    gate.enter(number: TarwinCall.syncWake, registers: CallRegisters(address, UInt64(count)))
  }
  public static func requeue<G: NativeGate>(
    _ address: UInt64, wake: UInt32, target: UInt64, move: UInt32, gate: inout G
  ) -> CallResult {
    gate.enter(
      number: TarwinCall.syncRequeue,
      registers: CallRegisters(address, UInt64(wake), target, UInt64(move)))
  }
}
