import XCTest

@testable import TarwinLoader

final class RIDLIdentityTests: XCTestCase {
  func testCompleteIdentityRequiredForCurrentAndSupportedABI() {
    let module = Array("LibTessera".utf8)
    let uuid = Array(UInt8(1)...16)
    let old = Array(UInt8(17)...32)
    let prefix: [UInt8] = [82, 73, 68, 76, 1, 0, 0, 0, 10, 0, 0, 0] + module + [2, 0, 0, 0]
    let trailer: [UInt8] =
      [1, 0, 0, 0, 5, 0, 0, 0] + Array("Other".utf8) + old
      + Array(repeating: 0, count: 32) + [1, 0, 0, 0, 1, 0, 0, 0, 70]
    let blob = prefix + uuid + [0] + old + [1] + trailer
    func accepts(_ bytes: [UInt8], _ id: [UInt8] = [], _ name: [UInt8] = []) -> Bool {
      bytes.withUnsafeBytes { b in
        (id.isEmpty ? uuid : id).withUnsafeBytes { u in
          (name.isEmpty ? module : name).withUnsafeBytes { n in
            RIDLMetadata(bytes: b).supports(RIDLIdentity(name: n, uuid: u))
          }
        }
      }
    }
    XCTAssertTrue(accepts(blob))
    XCTAssertTrue(accepts(blob, old))
    XCTAssertFalse(accepts(blob, uuid, Array("Other".utf8)))
    XCTAssertFalse(accepts(blob, Array(repeating: 3, count: 16)))
    XCTAssertFalse(accepts(prefix + uuid + [0] + old + [2] + trailer, old))
    XCTAssertFalse(accepts(prefix + uuid + [0] + old + [0] + trailer))
    XCTAssertFalse(accepts(prefix + uuid + [1] + old + [1] + trailer))
    XCTAssertFalse(accepts(prefix + uuid + [0] + uuid + [1] + trailer))
    XCTAssertFalse(accepts(blob + [0]))
    for n in 0..<blob.count { XCTAssertFalse(accepts(Array(blob.prefix(n)))) }
  }
}
