import TarwinBoot
import Testing

@Test func cryptoAgileEventLog() throws {
  func le(_ x: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: x >> ($0 * 8)) } }
  let banks: [UInt8] = [4, 0, 20, 0, 11, 0, 32, 0]
  let spec = Array("Spec ID Event03".utf8) + [0] + le(0) + [0, 2, 0, 2] + le(2) + banks + [0]
  let header = le(0) + le(3) + Array(repeating: UInt8(0), count: 20) + le(UInt32(spec.count)) + spec
  func event(_ pcr: UInt32, _ payload: UInt8) -> [UInt8] {
    le(pcr) + le(13) + le(2) + [4, 0] + Array(repeating: 0, count: 20) + [11, 0]
      + Array(repeating: 0, count: 32) + le(1) + [payload]
  }
  let a = event(8, 1)
  let b = event(9, 2)
  let c = event(5, 3)
  let primary = header + a + b
  let format = try #require(primary.withUnsafeBytes { EventLogFormat($0) })
  #expect(
    primary.withUnsafeBytes { format.primaryLength($0, last: header.count + a.count) }
      == primary.count)
  #expect(
    primary.withUnsafeBytes { format.primaryLength($0, last: header.count + a.count - 1) } == nil)
  for n in 0..<primary.count {
    let len = primary.prefix(n).withUnsafeBytes { bytes in
      EventLogFormat(bytes)?.primaryLength(bytes, last: header.count + a.count)
    }
    #expect(len == nil)
  }
  for index in [4, 8, 28, 32, 53, 55, 56, 62, 64] {
    var bad = header
    bad[index] ^= 16
    #expect(bad.withUnsafeBytes { EventLogFormat($0) } == nil)
  }
  var dup = a
  dup[34] = 4
  #expect(dup.withUnsafeBytes { format.event($0, at: 0) } == nil)
  let final = le(1) + le(0) + le(2) + le(0) + b + c
  func appended(_ f: [UInt8], _ baseline: UInt64) -> Range<Int>? {
    f.withUnsafeBytes { x in
      primary.withUnsafeBytes { format.finalSuffix(x, baseline: baseline, primary: $0) }
    }
  }
  #expect(appended(final, 1) == (16 + b.count)..<final.count)
  #expect(appended(final, 0) == 16..<final.count)
  #expect(appended(final, 3) == nil)
  var changed = final
  changed[16 + b.count - 1] ^= 1
  #expect(appended(changed, 1) == nil)
  for n in 0..<final.count { #expect(appended(Array(final.prefix(n)), 1) == nil) }
}
