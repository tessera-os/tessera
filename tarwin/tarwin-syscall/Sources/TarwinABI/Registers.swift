/// The order of logical words here is §10.2, not a C calling convention.
public enum CallISA {
  case aarch64, x64, rv64
  public var argumentCount: Int {
    switch self {
    case .aarch64: 8
    case .x64: 6
    case .rv64: 7
    }
  }
  public var instructionWidth: UInt64 { self == .x64 ? 2 : 4 }

  /// ELR and SYSCALL's RCX point past the instruction; SEPC points at ECALL.
  public func instruction(savedPC: UInt64) -> UInt64? {
    switch self {
    case .aarch64: return savedPC >= 4 && savedPC & 3 == 0 ? savedPC - 4 : nil
    case .x64: return savedPC >= 2 ? savedPC - 2 : nil
    case .rv64: return savedPC & 1 == 0 ? savedPC : nil
    }
  }
}

public struct CallRegisters {
  public var a0, a1, a2, a3, a4, a5, a6, a7: UInt64
  public init(
    _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0,
    _ a4: UInt64 = 0, _ a5: UInt64 = 0, _ a6: UInt64 = 0, _ a7: UInt64 = 0
  ) {
    (self.a0, self.a1, self.a2, self.a3, self.a4, self.a5, self.a6, self.a7) = (
      a0, a1, a2, a3, a4, a5, a6, a7
    )
  }
  public subscript(i: Int) -> UInt64 {
    get {
      switch i {
      case 0: a0
      case 1: a1
      case 2: a2
      case 3: a3
      case 4: a4
      case 5: a5
      case 6: a6
      case 7: a7
      default: preconditionFailure()
      }
    }
    set {
      switch i {
      case 0: a0 = newValue
      case 1: a1 = newValue
      case 2: a2 = newValue
      case 3: a3 = newValue
      case 4: a4 = newValue
      case 5: a5 = newValue
      case 6: a6 = newValue
      case 7: a7 = newValue
      default: preconditionFailure()
      }
    }
  }
}

public struct CallResult {
  public let status, detail, first, second: UInt64
  public init(status: UInt64 = 0, detail: UInt64 = 0, first: UInt64 = 0, second: UInt64 = 0) {
    self.status = status
    self.detail = detail
    self.first = first
    self.second = second
  }
  public var code: UInt32 { UInt32(truncatingIfNeeded: status) }
  public var subsystem: UInt16 { UInt16(truncatingIfNeeded: status >> 32) }
}
