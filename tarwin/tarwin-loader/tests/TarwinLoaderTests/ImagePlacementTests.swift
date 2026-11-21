import TarwinLoader
import XCTest

final class ImagePlacementTests: XCTestCase {
  let lo: UInt64 = 1 << 32, hi: UInt64 = 1 << 43, page: UInt64 = 16384
  let none = UnsafeBufferPointer<Range<UInt64>>(start: nil, count: 0)

  func testWindowAndLastAlignedStartOnEveryArchitecture() throws {
    XCTAssertEqual(imageWindow, lo..<hi)
    for machine in [ElfMachine.aarch64, ElfMachine.x64, ElfMachine.rv64] {
      let size = imagePage(machine)
      let s = try XCTUnwrap(
        ImagePlacementSpace(machine: machine, span: size * 2, alignment: size, occupied: none))
      let count = (hi - lo) / size - 1
      XCTAssertEqual(s.positions, count)
      XCTAssertEqual(s.reservation(randomWord: count), lo..<lo + size * 2)
      XCTAssertEqual(s.reservation(randomWord: count * 2 - 1), hi - size * 2..<hi)
      let threshold = (0 &- count) % count
      XCTAssertNotEqual(threshold, 0)
      XCTAssertNil(s.reservation(randomWord: threshold - 1))
      XCTAssertNotNil(s.reservation(randomWord: threshold))
    }
  }

  func testExactlyEnoughAfterFragmentationAndOneStartTooFew() throws {
    // Leave one run of three pages and one long run. Two-page images
    // lose one legal start per run; counting free pages would admit too many.
    let n = minimumImagePositions
    let cut = hi - (n - 1) * page
    let used = [lo + 3 * page..<cut]
    try used.withUnsafeBufferPointer { reserved in
      let s = try XCTUnwrap(
        ImagePlacementSpace(machine: 183, span: 2 * page, alignment: page, occupied: reserved))
      XCTAssertEqual(s.positions, n)
      XCTAssertEqual(s.reservation(randomWord: 0), lo..<lo + 2 * page)
      XCTAssertEqual(s.reservation(randomWord: 1), lo + page..<lo + 3 * page)
      XCTAssertEqual(s.reservation(randomWord: 2), cut..<cut + 2 * page)
      XCTAssertEqual(s.reservation(randomWord: .max), hi - 2 * page..<hi)
      for extra in [lo..<lo + page, hi - page..<hi] {
        let short = try XCTUnwrap(
          ImagePlacementSpace(
            machine: 183, span: 2 * page, alignment: page, occupied: reserved, excluding: extra))
        XCTAssertEqual(short.positions, n - 1)
        XCTAssertNil(short.reservation(randomWord: .max))
      }
    }
    let aligned = try XCTUnwrap(
      ImagePlacementSpace(machine: 183, span: page, alignment: page * 2, occupied: none))
    XCTAssertLessThan(aligned.positions, n)
    XCTAssertNil(aligned.reservation(randomWord: .max))
  }

  func testInvalidMapOrGeometryDoesNotSelect() {
    for used: [Range<UInt64>] in [
      [lo..<lo], [0..<lo], [hi..<hi + page], [lo..<lo + 1],
      [lo..<lo + page, lo..<lo + page], [lo + page..<lo + 2 * page, lo..<lo + page],
    ] {
      used.withUnsafeBufferPointer {
        XCTAssertNil(ImagePlacementSpace(machine: 183, span: page, alignment: page, occupied: $0))
      }
    }
    [lo..<lo + page].withUnsafeBufferPointer {
      XCTAssertNil(
        ImagePlacementSpace(
          machine: 183, span: page, alignment: page, occupied: $0, excluding: lo..<lo + page))
    }
    for (span, align) in [(0, page), (page + 1, page), (page, page - 1), (page, 3 * page)] {
      XCTAssertNil(ImagePlacementSpace(machine: 183, span: span, alignment: align, occupied: none))
    }
    XCTAssertNil(ImagePlacementSpace(machine: 0, span: page, alignment: page, occupied: none))
    XCTAssertEqual(
      ImagePlacementSpace(machine: 183, span: .max - page + 1, alignment: 1 << 63, occupied: none)?
        .positions, 0)
  }
}
