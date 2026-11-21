import TarwinBoot
import Testing

private struct EntropyPort: TpmPort {
  var bytes = [UInt8](repeating: 0xcc, count: 64)
  let chunk: Int
  var fault = 0
  var issued = 0
  var consumed = 0
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
  mutating func putByte(_ offset: UInt64, value: UInt8) { bytes[Int(offset)] = value }
  mutating func submit(_ size: UInt64) -> UInt64 {
    issued += 1
    let want = 32 - consumed
    guard size == 12, Array(bytes[..<12]) == [128, 1, 0, 0, 0, 12, 0, 0, 1, 123, 0, UInt8(want)]
    else { return 0 }
    let n = min(want, chunk)
    let total = n + 12
    bytes[0..<12] = [128, 1, 0, 0, 0, UInt8(total), 0, 0, 0, 0, 0, UInt8(n)]
    for i in 0..<n { bytes[12 + i] = UInt8(consumed + i) }
    consumed += n
    if issued == 2 {
      switch fault {
      case 1: bytes[1] = 2
      case 2: bytes[5] ^= 1
      case 3: bytes[9] = 1
      case 4: bytes[11] ^= 1
      case 5: return 0
      case 6: bytes[5] = 12; bytes[11] = 0; return 12
      case 7: return .max
      case 8: bytes[5] = 44; bytes[11] = 32; return 44
      default: break
      }
    }
    return UInt64(total)
  }
}

@available(macOS 26, *)
@Test func acceptsFullAndProgressiveTPMSamples() {
  for chunk in [1, 4, 7, 32] {
    var p = EntropyPort(chunk: chunk)
    var sample = InlineArray<32, UInt8>(repeating: 0xff)
    let ok = readTPMEntropy32(&p, into: &sample)
    #expect(ok && p.issued == (31 + chunk) / chunk)
    for i in 0..<32 { #expect(sample[i] == UInt8(i)) }
    #expect(p.bytes.allSatisfy { $0 == 0 })
  }
}

@available(macOS 26, *)
@Test func rejectsMalformedOrLostRepliesWithoutReturningAPartialSample() {
  for fault in 1...8 {
    var p = EntropyPort(chunk: 16, fault: fault)
    var sample = InlineArray<32, UInt8>(repeating: 0xff)
    let ok = readTPMEntropy32(&p, into: &sample)
    #expect(!ok && p.issued == 2)
    for i in 0..<32 { #expect(sample[i] == 0) }
    #expect(p.bytes.allSatisfy { $0 == 0 })
  }
  var short = EntropyPort(bytes: Array(repeating: 1, count: 43), chunk: 32)
  var sample = InlineArray<32, UInt8>(repeating: 0xff)
  let ok = readTPMEntropy32(&short, into: &sample)
  #expect(!ok && short.issued == 0)
  for i in 0..<32 { #expect(sample[i] == 0) }
}
