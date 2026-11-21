/// Called only for synchronous traps from the stopped AArch64 guest, never
/// EL2 exceptions. Register selectors use op0:op1:CRn:CRm:op2 bit order.
public func armSystemExit(
  esr: UInt64, interruptPending: Bool,
  allow: (UInt64, Bool) -> Bool, readGPR: (UInt64) -> UInt64
) -> ExitRecord? {
  guard esr & (1 << 25) != 0 else { return nil }
  let ec = (esr >> 26) & 63
  if ec == 1 && esr & 3 == 0 && !interruptPending { return idleExit() }
  guard ec == 0x18 else { return nil }
  let selector =
    (esr >> 20 & 3) << 14 | (esr >> 14 & 7) << 11
    | (esr >> 10 & 15) << 7 | (esr >> 1 & 15) << 3 | (esr >> 17 & 7)
  let reg = esr >> 5 & 31
  let write = esr & 1 == 0
  guard allow(selector, write) else { return nil }
  return ExitRecord(
    reason: .systemRegister, address: selector, width: 8, write: write,
    data: write && reg != 31 ? readGPR(reg) : 0, registerIndex: reg)
}

/// VS virtual-instruction exception (not illegal instruction). Handle only
/// WFI and CSR reads with suppressed writes. RMW, write-only, privileged and
/// unknown operations remain in the kernel's architecture exception path.
public func rvSystemExit(
  cause: UInt64, hstatus: UInt64, pc: UInt64, stval: UInt64,
  interruptPending: Bool, fetch: (UInt64) -> UInt16?,
  allowRead: (UInt64) -> Bool
) -> ExitRecord? {
  guard cause == 22, hstatus & 0x180 == 0x180, pc & 1 == 0, pc <= UInt64.max - 4 else { return nil }
  let inst: UInt64
  if stval == 0 {
    guard let lo = fetch(pc), lo & 0x7f == 0x73, let hi = fetch(pc + 2) else { return nil }
    inst = UInt64(hi) << 16 | UInt64(lo)
  } else {
    inst = stval
  }
  if inst == 0x1050_0073 && !interruptPending { return idleExit() }
  let kind = inst >> 12 & 7
  guard inst >> 32 == 0, inst & 0x7f == 0x73, inst & 0xf8000 == 0,
    kind == 2 || kind == 3 || kind == 6 || kind == 7, allowRead(inst >> 20)
  else { return nil }
  return ExitRecord(
    reason: .systemRegister, address: inst >> 20, width: 8, write: false,
    data: 0, registerIndex: inst >> 7 & 31)
}

private func idleExit() -> ExitRecord {
  ExitRecord(reason: .wait, address: 0, width: 0, write: false, data: 0, registerIndex: 0)
}
