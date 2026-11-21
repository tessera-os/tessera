import TarwinTaskProtocol
import TarwinTrapDecode

public enum HostedRewriteError: Error, Equatable {
  case invalidLayout
  case invalidTrapSite(UInt64)
  case branchOutOfRange(from: UInt64, to: UInt64)
}

public struct HostedRewrittenText {
  public let text: [UInt32]
  public let veneers: [UInt32]
  public let fatalTrapSites: [UInt64]
  public let gateTrapSites: [UInt64: UInt64]
}

public enum HostedTrapRewrite {
  public static let forbiddenTrap: UInt32 = 0xd42f_eae0
  public static let gateTrap: UInt32 = 0xd42f_eac0
  private static let nop: UInt32 = 0xd503_201f

  public static func isSyscallInstruction(_ word: UInt32) -> Bool {
    AArch64TrapInstruction.isSyscallInstruction(word)
  }

  /// Words and syscall sites come from the verified image before sealing.
  /// The task host publishes the native entry points on its read-only gate page.
  public static func rewrite(
    text: [UInt32], at base: UInt64, listedTraps: [UInt64],
    veneersAt veneerBase: UInt64
  ) throws -> HostedRewrittenText {
    let (end, overflows) = base.addingReportingOverflow(UInt64(text.count) * 4)
    guard !overflows, (base | veneerBase) & 3 == 0, !((base..<end).contains(veneerBase))
    else { throw HostedRewriteError.invalidLayout }

    let sites = Set(listedTraps)
    var seen = Set<UInt64>()
    for address in listedTraps {
      guard address >= base, address < end, address & 3 == 0,
        seen.insert(address).inserted, isSyscallInstruction(text[Int((address - base) / 4)])
      else { throw HostedRewriteError.invalidTrapSite(address) }
    }

    var rewritten = text
    var veneers: [UInt32] = []
    var fatal: [UInt64] = []
    var gateSites: [UInt64: UInt64] = [:]
    for (index, word) in text.enumerated() {
      let address = base + UInt64(index) * 4
      switch AArch64TrapInstruction.decode(word) {
      case .svc:
        guard sites.contains(address) else {
          rewritten[index] = forbiddenTrap
          fatal.append(address)
          continue
        }
        let call = gatePageCall(offset: TaskGatePage.gateEntryOffset)
        let veneer = try location(veneerBase, veneers.count, count: 2 + call.count, excluding: base..<end)
        rewritten[index] = try branch(from: address, to: veneer)
        gateSites[veneer] = address
        veneers.append(gateTrap)
        veneers += call
        veneers.append(try branch(from: veneer + UInt64(1 + call.count) * 4, to: address + 4))
      case .readThreadPointer(let destination):
        if destination == 31 {
          rewritten[index] = nop
          continue
        }
        let call = gatePageCall(offset: TaskGatePage.tlsEntryOffset)
        let veneer = try location(veneerBase, veneers.count, count: 4 + call.count, excluding: base..<end)
        rewritten[index] = try branch(from: address, to: veneer)
        let move = destination == 0 ? nop : 0xaa00_03e0 | destination
        let restore: UInt32
        switch destination {
        case 0: restore = 0xf841_07fe       // ldr x30, [sp], #16
        case 30: restore = 0xf841_07e0      // ldr x0, [sp], #16
        default: restore = 0xa8c1_7be0     // ldp x0, x30, [sp], #16
        }
        veneers.append(0xa9bf_7be0)         // stp x0, x30, [sp, #-16]!
        veneers += call
        veneers += [move, restore,
          try branch(from: veneer + UInt64(3 + call.count) * 4, to: address + 4)]
      case .other:
        break
      }
    }
    return HostedRewrittenText(
      text: rewritten, veneers: veneers, fatalTrapSites: fatal, gateTrapSites: gateSites)
  }

  private static func gatePageCall(offset: Int) -> [UInt32] {
    let page = TaskGatePage.address
    var code: [UInt32] = [0xa9bf_7bf1]     // stp x17, x30, [sp, #-16]!
    for i in 0..<4 {
      let immediate = UInt32(truncatingIfNeeded: page >> (i * 16)) & 0xffff
      let opcode: UInt32 = i == 0 ? 0xd280_0000 : 0xf280_0000
      code.append(opcode | UInt32(i) << 21 | immediate << 5 | 17)
    }
    code += [
      0xf940_0231 | UInt32(offset / 8) << 10, // ldr x17, [x17, #offset]
      0xd63f_0220,                         // blr x17
      0xa8c1_7bf1,                         // ldp x17, x30, [sp], #16
    ]
    return code
  }

  private static func location(
    _ base: UInt64, _ words: Int, count: Int, excluding text: Range<UInt64>
  ) throws -> UInt64 {
    let (first, overflow) = base.addingReportingOverflow(UInt64(words) * 4)
    let (end, endOverflow) = first.addingReportingOverflow(UInt64(count) * 4)
    guard !overflow, !endOverflow, !(first..<end).overlaps(text) else {
      throw HostedRewriteError.invalidLayout
    }
    return first
  }

  private static func branch(from: UInt64, to: UInt64) throws -> UInt32 {
    let forward = to >= from
    let bytes = forward ? to - from : from - to
    let limit: UInt64 = 1 << 27
    guard bytes & 3 == 0, bytes < limit || (!forward && bytes == limit) else {
      throw HostedRewriteError.branchOutOfRange(from: from, to: to)
    }
    let displacement = Int32(bytes / 4) * (forward ? 1 : -1)
    return 0x1400_0000 | (UInt32(bitPattern: displacement) & 0x03ff_ffff)
  }
}
