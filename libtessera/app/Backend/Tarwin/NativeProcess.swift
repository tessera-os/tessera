import TarwinABI

public enum NativeProcess {
  public static func exit<G: NativeGate>(_ code: Int64, gate: inout G) -> Never {
    _ = gate.enter(
      number: TarwinCall.processExit, registers: CallRegisters(UInt64(bitPattern: code)))
    fatalError("Process.exit returned")
  }
  public static func current<G: NativeGate>(gate: inout G) -> UInt64 {
    let r = gate.enter(number: TarwinCall.processCurrent, registers: CallRegisters())
    return r.status == 0 ? r.first : 0
  }
}

#if TARWIN_W1_EXPORT
  #if !hasFeature(Embedded) || !arch(arm64)
    #error("The W1 RIDL body requires Embedded Swift on AArch64")
  #endif
  @_extern(c, "libtessera_tarwin_current_gate")
  private func enterCurrent() -> UInt64

  /// Image-local body. The linker supplies the RIDL export veneer and
  /// its type tag from the independently frozen train SDK.
  @_cdecl("libtessera_tarwin_process_current_body")
  public func tarwinProcessCurrentBody() -> UInt64 {
    enterCurrent()
  }
#endif
