// Intel SDM vol. 3C: true control capability MSRs, EPTP and INVEPT.
// One pinned logical CPU, ordinary VMX (outside SMX), WB regions. No
// nested or confidential guest, VPID reuse, or posted interrupts enabled.
public struct VMXControls {
  public let revision: UInt32
  public let pin, primary, secondary, entry, exit: UInt64
  public let eptp: UInt64

  private static func adjusted(_ wanted: UInt64, _ msr: UInt64) -> UInt64? {
    let result = wanted | (msr & 0xffff_ffff)
    return result & ~(msr >> 32) == 0 ? result : nil
  }

  // Inputs are kernel-read capabilities, not a VMM's claims. The caller
  // pins both VMX regions and the whole EPT arena as private WB memory.
  public init?(
    vmx: Bool, featureControl: UInt64, basic: UInt64, physicalBits: UInt64,
    vmxonPA: UInt64, vmcsPA: UInt64, eptRoot: UInt64, eptCaps: UInt64,
    pinCaps: UInt64, primaryCaps: UInt64, secondaryCaps: UInt64, entryCaps: UInt64,
    exitCaps: UInt64
  ) {
    let size = (basic >> 32) & 0x1fff
    let eptRequired: UInt64 = (1 << 6) | (1 << 14) | (1 << 20) | (1 << 25)
    guard vmx, featureControl & 5 == 5, basic & (1 << 55) != 0,
      (basic >> 50) & 15 == 6, size > 0 && size <= 4096,
      physicalBits >= 32 && physicalBits <= 52,
      (vmxonPA | vmcsPA | eptRoot) & 4095 == 0, vmxonPA != vmcsPA,
      vmxonPA != eptRoot && vmcsPA != eptRoot,
      (vmxonPA | vmcsPA) >> (basic & (1 << 48) != 0 ? 32 : physicalBits) == 0,
      eptRoot >> physicalBits == 0, eptCaps & eptRequired == eptRequired,
      // §5 x64 profile: posted interrupts, unrestricted guest and EPT must
      // be available, even though this isolated test uses software exits.
      (pinCaps >> 32) & (1 << 7) != 0,
      (secondaryCaps >> 32) & 0x80 == 0x80,
      let pin = Self.adjusted(9, pinCaps),
      let primary = Self.adjusted(0x8100_0080, primaryCaps),  // secondary, unconditional I/O, HLT
      let secondary = Self.adjusted(2, secondaryCaps),
      let entry = Self.adjusted(0x8200, entryCaps),  // IA-32e guest, load EFER
      let exit = Self.adjusted(0x30_0200, exitCaps),  // 64-bit host, save/load EFER
      // Do not silently activate a control requiring an unprovided table,
      // interrupt descriptor, MSR list, preemption timer, or host policy.
      pin & ~0x1f == 0, secondary == 2,
      primary & ~UInt64(0x8100_0080 | 0x0401_e172) == 0,
      entry & ~UInt64(0x8200 | 0x11ff) == 0, exit & ~UInt64(0x30_0200 | 0x36dff) == 0
    else { return nil }
    revision = UInt32(basic & 0x7fff_ffff)
    self.pin = pin
    self.primary = primary
    self.secondary = secondary
    self.entry = entry
    self.exit = exit
    eptp = eptRoot | 0x1e  // WB, four levels, no hardware A/D
  }

  // Populate a freshly cleared, current VMCS. Fail fast on VMfail; no
  // launch until the caller has separately installed all host/guest state.
  public func install(write: (UInt64, UInt64) -> Bool) -> Bool {
    write(0x4000, pin) && write(0x4002, primary) && write(0x401e, secondary)
      && write(0x400c, exit) && write(0x4012, entry) && write(0x201a, eptp)
      && write(0x2800, UInt64.max) && write(0x4004, 0xffff_ffff)
      && write(0x4006, 0) && write(0x4008, 0) && write(0x400a, 0)
      && write(0x400e, 0) && write(0x4010, 0) && write(0x4014, 0) && write(0x4016, 0)
  }
}

// Owned with the VMCS by its one root-mode CPU. Any VMfail or VM-entry
// failure quarantines this VMCS until VMCLEAR; never retry as another guest.
public struct VMXRunState: ~Copyable {
  private var launched = false
  private var failed = false
  public init() {}
  public mutating func run(enter: (Bool) -> Bool, readReason: () -> UInt64?) -> UInt32? {
    guard !failed else { return nil }
    guard enter(launched), let reason = readReason(), reason < 1 << 16 else {
      failed = true
      return nil
    }
    launched = true
    return UInt32(reason)
  }
}
