import XCTest

@testable import CallIndex

final class CatalogueTests: XCTestCase {
  func testIndexAndGeneratedTables() throws {
    let doc = try String(
      contentsOf: Driver.packages.appendingPathComponent("tessera/roadmap/16-libtessera.md"),
      encoding: .utf8)
    let publicNames = try Catalogue.publicNames(in: doc)
    XCTAssertEqual(Set(publicNames).count, 135)
    XCTAssertTrue(Set(["File.read", "File.write", "Job.setPolicy"]).isSubset(of: publicNames))
    for (a, b) in [("Port (4)", "Port (5)"), ("Port.post,", "Port-post,")] {
      XCTAssertThrowsError(try Catalogue.publicNames(in: doc.replacingOccurrences(of: a, with: b)))
    }
    let source = try Driver.source()
    for output in [
      "tarwin/tarwin-syscall/Sources/TarwinSyscall/CallNumbers.swift",
      "libtessera/app/Backend/Tarwin/CallNumbers.swift",
    ] {
      XCTAssertEqual(
        try String(contentsOf: Driver.packages.appendingPathComponent(output), encoding: .utf8),
        source)
    }
  }
  func testStableBanks() throws {
    let names = ["Z.go", "A.go"]
    let first = ["C.go", "B.go"]
    let calls = try Catalogue.number(names, extensions: first + ["@0x10100", "Device.go"])
    XCTAssertEqual(Array(calls.dropLast()), try Catalogue.number(names, extensions: first))
    XCTAssertEqual(calls.map(\.number), [1, 2, 65536, 65537, 65792])
    XCTAssertEqual(calls.map(\.symbol), ["aGo", "zGo", "bGo", "cGo", "deviceGo"])
    for ext in [
      ["Ab.cdEf"], ["AbCd.ef"], ["Z.go", "@0x10000", "A.go"],
      ["Z.go", "@0xffffffffffffffff", "A.go", "B.go"], ["Z.go", "@0x10100"],
    ] {
      XCTAssertThrowsError(try Catalogue.number(["Ab.cdEf"], extensions: ext))
    }
  }
}
