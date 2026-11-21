/// Explicit scalar VS loads/stores faulting in an unbacked device aperture.
/// The caller owns the halted vCPU and both translation regimes. If htinst
/// is zero, fetch must read immutable, executable guest *virtual* text under
/// those same translations, or return nil (including a missing second half).
public struct RVMMIOAccess {
  public let address, width, register, nextPC: UInt64
  public let write: Bool
  private let signed: Bool
  public init?(
    cause: UInt64, hstatus: UInt64, stval: UInt64, htval: UInt64,
    htinst: UInt64, pc: UInt64, vsatp: UInt64, readGPR: (UInt64) -> UInt64,
    fetch: (UInt64) -> UInt16?,
    registered: (UInt64, UInt64) -> Bool
  ) {
    guard hstatus & 0xc0 == 0xc0, cause == 21 || cause == 23, pc & 1 == 0,
      htval > 0, htval < (1 << 48)
    else { return nil }
    address = (htval << 2) | (stval & 3)
    write = cause == 23
    var inst: UInt64
    let length: UInt64
    if htinst != 0 {
      // Bit 0 excludes implicit page-table walk pseudoinstructions. Bit 1
      // distinguishes a transformed compressed instruction (expanded to I).
      guard htinst >> 32 == 0, htinst & 1 == 1, htinst & 0xf8000 == 0 else { return nil }
      inst = htinst | 2
      length = htinst & 2 == 0 ? 2 : 4
    } else {
      // With no transformed instruction, a G-stage fault during an implicit
      // VS page walk cannot be distinguished by cause. Only retry Bare here.
      guard vsatp == 0, stval == address, let first = fetch(pc) else { return nil }
      inst = UInt64(first)
      if inst & 3 == 3 {
        guard inst & 31 != 31, pc <= UInt64.max - 4, let high = fetch(pc + 2) else { return nil }
        inst |= UInt64(high) << 16
        length = 4
      } else {
        length = 2
      }
    }
    guard pc <= UInt64.max - length else { return nil }
    nextPC = pc + length
    if inst & 3 == 3 {
      guard inst & 0x7f == (write ? 0x23 : 0x03) else { return nil }
      let kind = (inst >> 12) & 7
      guard kind < (write ? 4 : 7) else { return nil }
      width = 1 << (kind & 3)
      signed = !write && kind < 4
      register = (inst >> (write ? 20 : 7)) & 31
      let base = (inst >> 15) & 31
      let imm = write ? (inst >> 25) << 5 | (inst >> 7) & 31 : inst >> 20
      if htinst == 0 {
        let displacement = imm & 0x800 == 0 ? imm : imm | ~UInt64(0xfff)
        guard (base == 0 ? 0 : readGPR(base)) &+ displacement == stval else { return nil }
      } else if imm != 0 {
        return nil
      }
    } else {
      let q = inst & 3
      let kind = inst >> 13
      // C.LW/LD/SW/SD (prime-register) and their SP-relative forms.
      guard q == 0 || q == 2, write ? (kind == 6 || kind == 7) : (kind == 2 || kind == 3)
      else { return nil }
      width = kind & 1 == 0 ? 4 : 8
      signed = !write
      register = q == 0 ? 8 + ((inst >> 2) & 7) : (inst >> (write ? 2 : 7)) & 31
      guard write || q != 2 || register != 0 else { return nil }
      let base = q == 0 ? 8 + ((inst >> 7) & 7) : 2
      let displacement: UInt64
      if q == 0 {
        let extra = width == 4 ? (inst >> 4) & 4 | (inst << 1) & 64 : (inst << 1) & 192
        displacement = (inst >> 7) & 56 | extra
      } else if write {
        displacement =
          width == 4
          ? (inst >> 7) & 60 | (inst >> 1) & 192
          : (inst >> 7) & 56 | (inst >> 1) & 448
      } else {
        displacement =
          (inst >> 7) & 32
          | (width == 4
            ? (inst >> 2) & 28 | (inst << 4) & 192
            : (inst >> 2) & 24 | (inst << 4) & 448)
      }
      // Reject a fault address in the middle of a decomposed misaligned access.
      guard readGPR(base) &+ displacement == stval else { return nil }
    }
    guard address % width == 0, registered(address, width) else { return nil }
  }
  public func exit(readGPR: (UInt64) -> UInt64) -> ExitRecord {
    let mask = UInt64.max >> ((8 - width) * 8)
    return ExitRecord(
      reason: .mmio, address: address, width: width, write: write,
      data: write && register != 0 ? readGPR(register) & mask : 0, registerIndex: register)
  }
  public func completeLoad(_ value: UInt64, writeGPR: (UInt64, UInt64) -> Void) {
    guard !write, register != 0 else { return }
    let mask = UInt64.max >> ((8 - width) * 8)
    let data = value & mask
    writeGPR(register, signed && data & (1 << (width * 8 - 1)) != 0 ? data | ~mask : data)
  }
}
