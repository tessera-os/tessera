import TarwinABI

/// The native backend's private word transport; no direct user pointer is
/// retained across an asynchronous operation. Callers inspect status first.
public enum NativeHandles {
  public static func close<G: NativeGate>(_ name: UInt64, gate: inout G) -> CallResult {
    gate.enter(number: TarwinCall.handleClose, registers: CallRegisters(name))
  }
  public static func closeMany<G: NativeGate>(_ names: UnsafeBufferPointer<UInt64>, gate: inout G)
    -> CallResult
  {
    guard names.count <= Int(UInt32.max) else { return CallResult(status: 1) }
    return gate.enter(
      number: TarwinCall.handleCloseMany,
      registers: CallRegisters(UInt64(UInt(bitPattern: names.baseAddress)), UInt64(names.count)))
  }
  public static func duplicate<G: NativeGate>(_ name: UInt64, rights: UInt64, gate: inout G)
    -> CallResult
  {
    gate.enter(number: TarwinCall.handleDuplicate, registers: CallRegisters(name, rights))
  }
  public static func replace<G: NativeGate>(_ name: UInt64, rights: UInt64, gate: inout G)
    -> CallResult
  {
    gate.enter(number: TarwinCall.handleReplace, registers: CallRegisters(name, rights))
  }
  /// Four little-endian output words: type/reserved, rights, KOID, zero.
  public static func info<G: NativeGate>(
    _ name: UInt64, into words: UnsafeMutableBufferPointer<UInt64>, gate: inout G
  ) -> CallResult {
    guard words.count >= 4 else { return CallResult(status: 7, detail: 32) }
    return gate.enter(
      number: TarwinCall.handleInfo,
      registers: CallRegisters(name, UInt64(UInt(bitPattern: words.baseAddress))))
  }
}
