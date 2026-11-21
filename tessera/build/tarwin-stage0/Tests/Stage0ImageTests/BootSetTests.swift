import TarbootPreflight
import Testing

@testable import Stage0Image

@Test func archiveRoundTrip() throws {
  let kernel = (0..<35337).map { UInt8(truncatingIfNeeded: $0) }
  var bytes = try bootSet(kernel: kernel)
  func range(_ key: StaticString) -> Range<Int>? {
    var scratch = DigestScratch()
    return bytes.withUnsafeBytes { archive in
      let name = UnsafeRawBufferPointer(start: key.utf8Start, count: key.utf8CodeUnitCount)
      guard case .intact(let range) = inspectRawMember(archive, path: name, scratch: &scratch)
      else { return nil }
      return range
    }
  }
  let k = try #require(range("kernel"))
  let c = try #require(range("boot.json"))
  #expect(!k.overlaps(c))
  #expect(Array(bytes[k]) == kernel)
  #expect(
    String(decoding: bytes[c], as: UTF8.self)
      == #"{"flags":["debug"],"securityVersion":1,"slot":"A"}"#)
  bytes[k.lowerBound] ^= 1
  #expect(range("kernel") == nil)
  #expect(range("boot.json") == c)
  bytes[c.lowerBound] ^= 1
  #expect(range("boot.json") == nil)
}
