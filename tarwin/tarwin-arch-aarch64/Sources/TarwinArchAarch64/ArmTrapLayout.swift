/// Byte offsets in the VHE host vector's 16-byte-aligned private stack frame.
/// ELR points past SVC; only x0...x3 may change during synchronous dispatch.
public enum ArmTrapLayout {
  public static let sp = 248, elr = 256, spsr = 264, esr = 272, tpidr = 280
  public static let fpcr = 288, fpsr = 296, vectors = 304
  public static let size = vectors + 32 * 16
}

/// Untagged W1 syscall tail. Hold the current process and its map stable;
/// load must use the VHE unprivileged instruction and its exact fault fixup.
/// No caller-supplied address is dereferenced as a kernel pointer.
@unsafe public func copyArmUserWords(
  from address: UInt64, range: Range<UInt64>,
  into words: UnsafeMutableBufferPointer<UInt64>,
  load: (UInt64, UnsafeMutablePointer<UInt64>) -> Bool
) -> Bool {
  guard !words.isEmpty, let out = words.baseAddress,
    address & 7 == 0, range.lowerBound >= 1 << 32, range.upperBound <= 1 << 47,
    range.contains(address), UInt64(words.count) <= (range.upperBound - address) / 8
  else { return false }
  for i in words.indices {
    if !load(address + UInt64(i) * 8, out + i) {
      for j in words.indices { out[j] = 0 }
      return false
    }
  }
  return true
}
