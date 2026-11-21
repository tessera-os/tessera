import XCTest

@testable import TvGpuGuest

final class ModuleTests: XCTestCase {
  // Only a framing fixture. The two opaque section bytes are not executable
  // code; the verification callback in the first test must refuse them.
  func envelope() -> [UInt8] {
    var bytes: [UInt8] = []
    for i in 0..<130 { bytes.append(0) }
    bytes[0] = 84
    bytes[1] = 86
    bytes[2] = 73
    bytes[3] = 83
    bytes[4] = 26
    bytes[5] = 11
    bytes[6] = 1
    bytes[8] = 65
    bytes[16] = 2
    bytes[20] = 1
    bytes[56] = 130
    bytes[64] = 9
    bytes[72] = 128
    bytes[80] = 1
    bytes[88] = 1
    bytes[96] = 11
    bytes[104] = 129
    bytes[112] = 1
    bytes[120] = 1
    return bytes
  }

  func testCanonicalEnvelopeCannotBypassSemanticVerifierOrHostCapabilityIntersection() {
    let image = envelope()
    let c = DeviceCaps(family: 1, host: 3, translated: 6, guestLowered: 8)
    let t = ModuleTarget(year: 26, month: 11, week: 1, required: 10)
    XCTAssertTrue(moduleEnvelope(image, 26, 11, 1))
    XCTAssertTrue(!c.supports(1))
    XCTAssertTrue(!c.supports(4))
    XCTAssertTrue(c.supports(10))
    var submitted = false
    let never: ([UInt8]) -> Bool = { b in return false }
    let transport: ([UInt8]) -> Bool = { b in
      submitted = true
      return true
    }
    XCTAssertTrue(!submitModule(image, t, c, never, transport))
    XCTAssertTrue(!submitted)
  }

  func testRejectsTruncatedReorderedAndCompressedDeliverySections() {
    var image = envelope()
    image[104] = 128
    XCTAssertTrue(!moduleEnvelope(image, 26, 11, 1))
    image[104] = 129
    image[100] = 1
    XCTAssertTrue(!moduleEnvelope(image, 26, 11, 1))
    image[100] = 0
    image[120] = 0
    XCTAssertTrue(!moduleEnvelope(image, 26, 11, 1))
  }
}
