// Scalar, little-endian AArch64 MMIO only. Decoded exclusively from a
// stopped CPU's private exception bank, not from the VMM's exit reply.
// Other instructions/faults stay guest exceptions rather than MMIO effects.
public struct ArmMMIOAccess {
  public let address: UInt64
  public let width: UInt64
  public let write: Bool
  public let register: UInt64
  private let signExtend: Bool
  private let wideRegister: Bool
  private let mask: UInt64

  public init?(esr: UInt64, far: UInt64, hpfar: UInt64, registered: (UInt64, UInt64) -> Bool) {
    let dfsc = esr & 0x3f
    guard (esr >> 26) & 63 == 0x24, dfsc == 6 || dfsc == 7,
      esr & (3 << 24) == (3 << 24),  // IL, ISV
      esr & 0x6780 == 0  // AR, VNCR, FnV, EA, CM, S1PTW
    else { return nil }
    width = 1 << ((esr >> 22) & 3)
    address = ((hpfar & 0xff_ffff_fff0) << 8) | (far & 0xfff)
    guard address < ArmStageTwo.ipaLimit, address % width == 0 else { return nil }
    write = esr & 0x40 != 0
    register = (esr >> 16) & 31
    signExtend = esr & (1 << 21) != 0
    wideRegister = esr & (1 << 15) != 0
    guard !(signExtend && write), width != 8 || (wideRegister && !signExtend),
      registered(address, width)
    else { return nil }
    mask = UInt64.max >> ((8 - width) * 8)
  }

  public func exit(readGPR: (UInt64) -> UInt64) -> ExitRecord {
    let value = write && register != 31 ? readGPR(register) & mask : 0
    return ExitRecord(
      reason: .mmio, address: address, width: width, write: write, data: value,
      registerIndex: register)
  }

  // Call only after successful service of this exact stopped vCPU exit,
  // before advancing its PC. Rt=31 discards a read (but still reaches MMIO).
  public func completeLoad(_ value: UInt64, writeGPR: (UInt64, UInt64) -> Void) {
    guard !write, register != 31 else { return }
    var result = value & mask
    if signExtend && result & (1 << (width * 8 - 1)) != 0 { result |= ~mask }
    writeGPR(register, wideRegister ? result : result & 0xffff_ffff)
  }
}
