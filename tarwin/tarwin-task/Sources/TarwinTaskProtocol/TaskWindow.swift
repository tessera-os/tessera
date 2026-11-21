public enum TaskWindow {
  public static let base: UInt64 = 0x0070_0000_0000
  public static let size: UInt64 = 64 << 30
  public static let pageSize: UInt64 = 16 << 10

  public static func contains(address: UInt64, length: UInt64) -> Bool {
    guard address >= base, address & (pageSize - 1) == 0,
      length != 0, length & (pageSize - 1) == 0
    else { return false }
    let offset = address - base
    return offset < size && length <= size - offset
  }
}
