// Register offsets, bits and PM4 encodings from Mesa 98fc8b8f:
// src/freedreno/registers/adreno/{a6xx.xml,adreno_pm4.xml,adreno_common.xml}.
// MIT: ../../MESA-LICENSE.txt. Offsets are in dwords, A6XX-A7XX variants.

public enum AdrenoRegister {
  public static let RBBM_INT_CLEAR_CMD: UInt32 = 0x0037
  public static let RBBM_INT_0_MASK: UInt32 = 0x0038
  public static let RBBM_INT_0_STATUS: UInt32 = 0x0201
  public static let CP_RB_BASE: UInt32 = 0x0800
  public static let CP_RB_BASE_HI: UInt32 = 0x0801
  public static let CP_RB_CNTL: UInt32 = 0x0802
  public static let CP_RB_RPTR: UInt32 = 0x0806
  public static let CP_RB_WPTR: UInt32 = 0x0807
  public static let CP_ALWAYS_ON_COUNTER: UInt32 = 0x0980
  public static let CP_ALWAYS_ON_COUNTER_HI: UInt32 = 0x0981
  /// Highest dword offset the provider touches.
  static let highest: UInt32 = CP_ALWAYS_ON_COUNTER_HI
}

public enum AdrenoInterrupt {
  public static let CP_AHB_ERROR: UInt32 = 1 << 1
  public static let CP_HW_ERROR: UInt32 = 1 << 9
  public static let CP_CACHE_FLUSH_TS: UInt32 = 1 << 20
  public static let RBBM_HANG_DETECT: UInt32 = 1 << 23
  public static let fatal: UInt32 = CP_AHB_ERROR | CP_HW_ERROR | RBBM_HANG_DETECT
  public static let enabled: UInt32 = fatal | CP_CACHE_FLUSH_TS
}

public enum AdrenoPM4 {
  public static let CP_NOP: UInt32 = 0x10
  public static let CP_INDIRECT_BUFFER: UInt32 = 0x3f
  public static let CP_EVENT_WRITE7: UInt32 = 0x46
  public static let CACHE_FLUSH_TS: UInt32 = 0x4
  /// EVENT=CACHE_FLUSH_TS, WRITE_SRC=EV_WRITE_USER_32B, WRITE_DST=EV_DST_RAM, WRITE_ENABLED, IRQ.
  public static let fenceEvent: UInt32 = CACHE_FLUSH_TS | 1 << 27 | 1 << 31
  public static let maxIBDwords: UInt32 = 0xf_ffff

  static func oddParity(_ input: UInt32) -> UInt32 {
    var value = input
    value ^= value >> 16
    value ^= value >> 8
    value ^= value >> 4
    return (~UInt32(0x6996) >> (value & 0xf)) & 1
  }

  public static func pkt7(_ opcode: UInt32, count: UInt32) -> UInt32 {
    precondition(opcode <= 0x7f && count <= 0x3fff)
    return 0x7000_0000 | count | oddParity(count) << 15 | opcode << 16 | oddParity(opcode) << 23
  }

  /// Returns (opcode, count) for a well-formed type-7 header.
  public static func decode7(_ header: UInt32) -> (opcode: UInt32, count: UInt32)? {
    guard header & 0xf000_0000 == 0x7000_0000 else { return nil }
    let count = header & 0x3fff
    let opcode = (header >> 16) & 0x7f
    guard header == pkt7(opcode, count: count) else { return nil }
    return (opcode, count)
  }

  /// AXXX_CP_RB_CNTL: BUFSZ = log2(bytes / 8), BLKSZ = log2(32 / 8), NO_UPDATE.
  static func ringControl(bytes: UInt32) -> UInt32 {
    UInt32((bytes / 8).trailingZeroBitCount) | 2 << 8 | 1 << 27
  }
}
