import TarbootPreflight
import Testing

@testable import Stage0Image

@Test func stage1ContainsFourDisjointVerbatimMembers() throws {
  let kernel: [UInt8] = [7, 0, 1], process: [UInt8] = [9, 8], library: [UInt8] = [3, 4, 0, 5]
  var bytes = try stage1BootSet(kernel: kernel, initialProcess: process, library: library)
  #expect(bytes == (try stage1BootSet(kernel: kernel, initialProcess: process, library: library)))
  #expect(Array(bytes[8..<16]) == [4, 0, 0, 0, 0, 0, 0, 0])
  let config = Array(#"{"flags":["debug"],"securityVersion":1,"slot":"A"}"#.utf8)
  var previous = 24
  for (name, input) in [("LibTessera", library), ("boot.json", config), ("kernel", kernel),
    ("tessera.init", process)] {
    func extent() -> Range<Int>? {
      var scratch = DigestScratch()
      return Array(name.utf8).withUnsafeBytes { path in
        bytes.withUnsafeBytes { raw in
          guard case .intact(let r) = inspectRawMember(raw, path: path, scratch: &scratch)
          else { return nil }
          return r
        }
      }
    }
    let range = try #require(extent())
    #expect(range == previous..<(previous + input.count))
    #expect(Array(bytes[range]) == input)
    bytes[range.lowerBound] ^= 1
    #expect(extent() == nil)
    bytes[range.lowerBound] ^= 1
    previous = range.upperBound
  }
  for i in 0..<3 {
    #expect(throws: InputError.self) {
      try stage1BootSet(kernel: i == 0 ? [] : kernel, initialProcess: i == 1 ? [] : process,
        library: i == 2 ? [] : library)
    }
  }
}

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
