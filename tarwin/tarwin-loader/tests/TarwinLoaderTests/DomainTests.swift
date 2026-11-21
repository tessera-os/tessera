import XCTest

@testable import TarwinLoader

func segment(_ addr: UInt64, _ flags: UInt32, _ bytes: UInt64) -> LoadSegment {
  return LoadSegment(
    fileOffset: 0, fileBytes: 64, virtualAddress: addr,
    memoryBytes: bytes, alignment: 4096, flags: flags)
}

final class TarwinLoaderTests: XCTestCase {
  func testDomainContracts() {
    let hdr = ImageHeader(
      magic: 0x464c_457f, wordClass: 2, encoding: 1,
      identVersion: 1, version: 1, kind: 3, machine: ElfMachine.rv64,
      headerBytes: 64, programOffset: 64, entryBytes: 56, count: 2)
    XCTAssertTrue(hdr.accepts(ElfMachine.rv64, 176))
    XCTAssertFalse(hdr.accepts(ElfMachine.rv64, 175))
    XCTAssertFalse(hdr.accepts(ElfMachine.x64, 176))
    XCTAssertFalse(imageContains(18_446_744_073_709_551_615, 18_446_744_073_709_551_608, 8))
    let text = segment(4096, 5, 4097)
    let data = segment(12288, 6, 4096)
    let overlap = segment(8192, 6, 4096)
    let wx = segment(4096, 7, 4096)
    let short = segment(4096, 4, 63)
    XCTAssertFalse(text.valid(ElfMachine.aarch64, 64, 65536))
    XCTAssertFalse(wx.valid(ElfMachine.rv64, 64, 65536))
    XCTAssertFalse(short.valid(ElfMachine.rv64, 64, 65536))
    var order = LoadOrder(afterLastPage: 0, seen: false)
    XCTAssertTrue(order.append(text, ElfMachine.rv64, 64, 65536))
    XCTAssertFalse(order.append(overlap, ElfMachine.rv64, 64, 65536))
    XCTAssertTrue(order.append(data, ElfMachine.rv64, 64, 65536))
    XCTAssertTrue(forbiddenProgramHeader(3))
    XCTAssertTrue(forbiddenProgramHeader(2))
    var relr = RelativeCursor(anchorSeen: false, nextBase: 0, bits: 0, at: 0, imageSize: 4096)
    XCTAssertFalse(relr.accept(3))
    XCTAssertFalse(relr.accept(6))
    XCTAssertTrue(relr.accept(8))
    XCTAssertFalse(relr.accept(3))
    XCTAssertEqual(relr.take(), 8)
    XCTAssertTrue(relr.accept(11))
    XCTAssertEqual(relr.take(), 16)
    XCTAssertEqual(relr.take(), 32)
    XCTAssertEqual(relr.take(), 0xffff_ffff_ffff_ffff)
    XCTAssertFalse(relr.accept(8))
    XCTAssertTrue(relr.accept(4080))
    XCTAssertEqual(relr.take(), 4080)
    XCTAssertFalse(relr.accept(5))
    XCTAssertTrue(relr.accept(3))
    XCTAssertEqual(relr.take(), 4088)
    XCTAssertEqual(integrityCases(), 0)
  }
}
