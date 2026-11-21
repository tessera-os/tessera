/// Local CPU registers; never expose this interface to a process. Caller
/// owns the CPU's timer and installed IDT vector, not the firmware timer.
public protocol X64DeadlineRegisters {
  mutating func interruptsMasked() -> Bool
  mutating func apicBase() -> UInt64
  mutating func spuriousVector() -> UInt64
  mutating func timerLVT() -> UInt64
  mutating func setDeadline(_ tsc: UInt64)
}

/// No APIC mode switch, vector installation, or fallback to a periodic
/// timer. Refuse unsupported CPUs before accessing any APIC/TSC MSR.
public func applyX64Deadline<R: X64DeadlineRegisters>(
  _ target: UInt64?, features: X64TargetFeatures, vector: UInt8, registers: inout R
) -> Bool {
  guard features.hasX2APICAndTSC, features.invariantCounter, features.deadlineTimer,
    vector >= 32, vector < 255, target != 0, registers.interruptsMasked(),
    registers.apicBase() & 0xc00 == 0xc00, registers.spuriousVector() & 0x100 != 0
  else { return false }
  let lvt = registers.timerLVT()
  guard lvt & 0x7_00ff == 0x4_0000 | UInt64(vector) else { return false }
  registers.setDeadline(target ?? 0)
  return true
}

#if arch(x86_64) && os(none) && hasFeature(Embedded) && hasFeature(Extern)
  @_extern(c, "tarwin_local_irq_masked") private func masked() -> UInt64
  @_extern(c, "tarwin_local_apic_base") private func base() -> UInt64
  @_extern(c, "tarwin_local_svr") private func svr() -> UInt64
  @_extern(c, "tarwin_local_lvt") private func lvt() -> UInt64
  @_extern(c, "tarwin_local_tsc_compare") private func program(_ value: UInt64)

  public struct X64LocalDeadlineRegisters: X64DeadlineRegisters {
    public init() {}
    public func interruptsMasked() -> Bool { masked() == 1 }
    public func apicBase() -> UInt64 { base() }
    public func spuriousVector() -> UInt64 { svr() }
    public func timerLVT() -> UInt64 { lvt() }
    public func setDeadline(_ tsc: UInt64) { program(tsc) }
  }
#endif
