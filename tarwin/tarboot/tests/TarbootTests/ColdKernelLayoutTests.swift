import XCTest
import Tarboot

final class ColdKernelLayoutTests: XCTestCase {
  func testPhysicalABIHasDisjointStorageAndBoundsTheArchive() throws {
    let k = try XCTUnwrap(ColdKernelLayout(handoff: 0x4800_0000))
    XCTAssertEqual(k.table, k.handoff + 4096 + UInt64(ColdKernelLayout.mapBytes))
    XCTAssertEqual(k.commands, k.table + 4096)
    XCTAssertEqual(k.signature, k.commands + 4096)
    XCTAssertEqual(k.scratch, k.signature + 65536)
    XCTAssertEqual(k.end, k.handoff + UInt64(ColdKernelLayout.pages) * 4096)
    XCTAssertTrue(k.containsSeparateArchive(k.handoff - 4096, bytes: 4096))
    XCTAssertTrue(k.containsSeparateArchive(k.end, bytes: 1))
    XCTAssertFalse(k.containsSeparateArchive(k.handoff - 4096, bytes: 4097))
    for a in [k.handoff, k.table, k.commands, k.signature, k.scratch,
              k.end - 4096, k.end + 1, 0x6000_0000, .max] {
      XCTAssertFalse(k.containsSeparateArchive(a, bytes: 1))
    }
    XCTAssertFalse(k.containsSeparateArchive(k.end, bytes: .max))
    XCTAssertFalse(k.containsSeparateArchive(k.end, bytes: 0))
    for a: UInt64 in [0, 0x3fff_f000, 0x4000_0001, 0x5fff_f000, .max] {
      XCTAssertNil(ColdKernelLayout(handoff: a))
    }
  }
}
