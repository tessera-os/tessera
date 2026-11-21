/// W0's restricted canonical JSON subset, not release slot policy. The input
/// remains untrusted until its containing TIRA is authorized independently.
public struct DebugBootConfig {
  public let slot: UInt8
  public let securityVersion: UInt64

  public init?(_ bytes: UnsafeRawBufferPointer) {
    var pos = 0
    func consume(_ token: StaticString) -> Bool {
      guard token.utf8CodeUnitCount <= bytes.count - pos else { return false }
      for i in 0..<token.utf8CodeUnitCount where bytes[pos + i] != token.utf8Start[i] {
        return false
      }
      pos += token.utf8CodeUnitCount
      return true
    }
    guard consume(#"{"flags":["debug"],"securityVersion":"#) else { return nil }
    let start = pos
    var v: UInt64 = 0
    while pos < bytes.count, (48...57).contains(bytes[pos]) {
      if pos != start && v == 0 { return nil }
      v = v * 10 + UInt64(bytes[pos] - 48)
      // Larger values cannot be expressed as interoperable JSON integers.
      if v > 9_007_199_254_740_991 { return nil }
      pos += 1
    }
    guard pos > start, consume(#","slot":""#), pos < bytes.count,
      bytes[pos] == 65 || bytes[pos] == 66
    else { return nil }
    slot = bytes[pos] - 65
    pos += 1
    guard consume(#""}"#), pos == bytes.count else { return nil }
    securityVersion = v
  }
}
