import TarwinABI

/// Private train-matched register ABI, not an SDK record.
public enum NativeObject {
  public enum WaitMode: UInt32 { case once, level, edge }
  public static func waitAsync<G: NativeGate>(
    _ source: UInt64, signals: UInt32, mode: WaitMode, port: UInt64, key: UInt64, gate: inout G
  ) -> CallResult {
    gate.enter(
      number: TarwinCall.objectWaitAsync,
      registers: CallRegisters(source, UInt64(signals), UInt64(mode.rawValue), port, key))
  }
}

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
