import XCTest

@testable import TarwinLoader

final class EnvelopeTests: XCTestCase {
  func testSignatureOmissionMatchesPhysicalRemovalAcrossChunkBoundaries() throws {
    var stack = Array(repeating: initialCv(), count: 54)
    let input = (0..<8299).map { UInt8($0 % 251) }
    for start in [63, 1021, 4096] {
      let omitted = start..<start + 3373
      for id in [3..<35, 8219..<8251] {
        let hash = input.withUnsafeBytes { b in
          stack.withUnsafeMutableBufferPointer {
            digestImage(b, zeros: id, omit: omitted, stack: $0)
          }
        }
        var raw = input
        raw.replaceSubrange(id, with: repeatElement(0, count: id.count))
        raw.removeSubrange(omitted)
        let expected = raw.withUnsafeBytes { b in
          stack.withUnsafeMutableBufferPointer { bootSetDigest(b, scratch: $0) }
        }
        XCTAssertTrue(try XCTUnwrap(hash).matches(XCTUnwrap(expected)))
      }
    }
  }
  func testBothSignaturesRequiredAndNoTrailingBytes() {
    var bytes = [UInt8](repeating: 0, count: 8 + 2 + 64 + 3309)
    bytes[0..<8] = [84, 83, 71, 49, 2, 0, 0, 0]
    func parse(_ b: [UInt8]) -> HybridEnvelope? {
      b.withUnsafeBytes { HybridEnvelope($0, descriptor: 0..<$0.count) }
    }
    XCTAssertEqual(parse(bytes)?.ed25519, 10..<74)
    XCTAssertEqual(parse(bytes)?.mldsa65, 74..<bytes.count)
    XCTAssertNil(parse(Array(bytes.dropLast())))
    XCTAssertNil(parse(bytes + [0]))
    bytes[4] = 0
    XCTAssertNil(parse(bytes))
  }
}
