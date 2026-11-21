import TarwinABI

public enum NativeEvents {
  public static func create<G: NativeGate>(initial: UInt32, gate: inout G) -> CallResult {
    gate.enter(number: TarwinCall.eventCreate, registers: CallRegisters(UInt64(initial)))
  }
  public static func pair<G: NativeGate>(gate: inout G) -> CallResult {
    gate.enter(number: TarwinCall.eventPairCreate, registers: CallRegisters())
  }
  public static func signal<G: NativeGate>(
    _ handle: UInt64, set: UInt32, clear: UInt32, gate: inout G
  ) -> CallResult {
    gate.enter(
      number: TarwinCall.objectSignal, registers: CallRegisters(handle, UInt64(set), UInt64(clear)))
  }
}
