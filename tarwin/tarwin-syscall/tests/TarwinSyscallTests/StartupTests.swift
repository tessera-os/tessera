import TarwinABI
import XCTest

final class StartupTests: XCTestCase {
  private let id = StartupIdentity(flags: 3, app: 0x0102_0304_0506_0708, process: 42, job: 11)!
  private func bytes(_ tags: [UInt32]) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0xff, count: 48 + 8 * tags.count)
    let size = bytes.withUnsafeMutableBytes { b in
      tags.withUnsafeBufferPointer { id.encode(tags: $0, into: b) }
    }
    return size == bytes.count ? bytes : nil
  }
  private func decode(_ bytes: [UInt8], _ names: [UInt64]) -> [StartupEntry]? {
    var entries = [StartupEntry](repeating: StartupEntry(), count: names.count)
    let result = bytes.withUnsafeBytes { b in
      names.withUnsafeBufferPointer { n in
        entries.withUnsafeMutableBufferPointer { StartupIdentity.decode(b, received: n, into: $0) }
      }
    }
    guard let result else {
      XCTAssertTrue(entries.allSatisfy { $0.tag == 0 && $0.name == 0 })
      return nil
    }
    XCTAssertEqual(result, id)
    return entries
  }

  func testWireBytesAndOutOfBandHandleIndices() throws {
    var b = try XCTUnwrap(bytes([13, 4096]))
    XCTAssertEqual(
      Array(b.prefix(24)),
      [
        0x54, 0x52, 0x53, 0x54, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1,
      ])
    XCTAssertEqual(
      Array(b[40...]), [0, 0, 0, 0, 0, 0, 0, 0, 13, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 1, 0, 0, 0])
    b.swapAt(52, 60)
    let entries = try XCTUnwrap(decode(b, [440, 660]))
    XCTAssertEqual(entries.map(\.tag), [13, 4096])
    XCTAssertEqual(entries.map(\.name), [660, 440])
    XCTAssertEqual(decode(try XCTUnwrap(bytes([])), [])?.count, 0)
  }
  func testRejectsMalformedMessageWithoutPublishingAPrefix() throws {
    let b = try XCTUnwrap(bytes([13, 14]))
    for (offset, value): (Int, UInt8) in [
      (0, 0), (4, 2), (8, 1), (12, 8), (24, 0), (32, 0),
      (40, 1), (56, 17), (56, 13), (60, 0), (60, 2),
    ] {
      var bad = b
      bad[offset] = value
      XCTAssertNil(decode(bad, [1, 2]), "offset \(offset)")
    }
    XCTAssertNil(decode(Array(b.dropLast()), [1, 2]))
    XCTAssertNil(decode(b + [0], [1, 2]))
    XCTAssertNil(decode(b, [4, 4]))
    XCTAssertNil(decode(b, [4, 0]))
    XCTAssertNil(decode(b, [4]))
    XCTAssertNil(bytes([0]))
    XCTAssertNil(bytes([13, 13]))
    XCTAssertNil(bytes([4095]))
    let tags = (4096..<4160).map(UInt32.init)
    XCTAssertEqual(decode(try XCTUnwrap(bytes(tags)), (1...64).map(UInt64.init))?.count, 64)
    XCTAssertNil(bytes(tags + [4160]))
  }
}
