import TarwinSyscall

// Borrow only integer slots from the private entry/exit save area. In
// particular this set cannot name PC, privileged controls or exit metadata.
public struct GuestIntegerRegisters {
  private enum Layout { case arm64, x64, rv64 }
  private let layout: Layout
  private let spilled: UnsafeMutableBufferPointer<UInt64>
  private let sp, ax: UnsafeMutablePointer<UInt64>?

  private init(
    _ layout: Layout, _ spilled: UnsafeMutableBufferPointer<UInt64>,
    _ sp: UnsafeMutablePointer<UInt64>? = nil, _ ax: UnsafeMutablePointer<UInt64>? = nil
  ) {
    self.layout = layout
    self.spilled = spilled
    self.sp = sp
    self.ax = ax
  }

  public static func arm64(
    x0Through30: UnsafeMutableBufferPointer<UInt64>, spEL1: UnsafeMutablePointer<UInt64>
  ) -> Self? {
    guard x0Through30.count == 31 else { return nil }
    return Self(.arm64, x0Through30, spEL1)
  }

  public static func rv64(x0Through31: UnsafeMutableBufferPointer<UInt64>) -> Self? {
    guard x0Through31.count == 32 else { return nil }
    return Self(.rv64, x0Through31)
  }

  // Entry stub spill order: RBX, RCX, RDX, RSI, RDI, RBP, R8...R15.
  // RAX and RSP may live in a hardware save area or private shadow slots.
  public static func x64(
    spills: UnsafeMutableBufferPointer<UInt64>, rax: UnsafeMutablePointer<UInt64>,
    rsp: UnsafeMutablePointer<UInt64>
  ) -> Self? {
    guard spills.count == 14 else { return nil }
    return Self(.x64, spills, rsp, rax)
  }

  public var count: Int { layout == .x64 ? 16 : 32 }

  // Arm: X0...X30, SP. RV: X0...X31. x64: architectural ModRM register order.
  private func slot(_ i: Int) -> UnsafeMutablePointer<UInt64>? {
    var offset = i
    switch layout {
    case .arm64: if i == 31 { return sp }
    case .rv64: if i == 0 { return nil }
    case .x64:
      switch i {
      case 0: return ax
      case 3: offset = 0
      case 4: return sp
      case 6: offset = 3
      case 7: offset = 4
      case 8...15: offset = i - 2
      default: break
      }
    }
    return spilled.baseAddress?.advanced(by: offset)
  }

  // The caller holds the pinned vCPU's state lock throughout and has already
  // resolved rights and copied user input into disjoint, private scratch.
  public func transfer(
    _ call: UInt64, cpu: VirtualCpuState, words: UnsafeMutableBufferPointer<UInt64>
  ) -> HvError {
    guard call == TarwinCall.virtualCpuGetRegisters || call == TarwinCall.virtualCpuSetRegisters,
      words.count == count
    else { return .invalid }
    guard !cpu.running else { return .busy }
    if call == TarwinCall.virtualCpuSetRegisters {
      guard layout != .rv64 || words[0] == 0 else { return .invalid }
      for i in 0..<count { slot(i)?.pointee = words[i] }
    } else {
      for i in 0..<count { words[i] = slot(i)?.pointee ?? 0 }
    }
    return .ok
  }
}
