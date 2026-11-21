import Foundation
import TarwinArchive
import TarwinReadOnlyFS
import XCTest

private let endOfArchive = [UInt8](repeating: 0, count: 1024)
private func archiveRecord(
  _ name: String, type: UInt8 = 48, data: [UInt8] = [],
  adjust: (inout [UInt8]) -> Void = { _ in }
) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: 512)
  b.replaceSubrange(0..<name.utf8.count, with: name.utf8)
  b.replaceSubrange(124..<135, with: String(format: "%011llo", UInt64(data.count)).utf8)
  b.replaceSubrange(148..<156, with: repeatElement(32, count: 8))
  b[156] = type
  b.replaceSubrange(257..<265, with: [117, 115, 116, 97, 114, 0, 48, 48])
  adjust(&b)
  let sum = b.reduce(0) { $0 + Int($1) }
  b.replaceSubrange(148..<154, with: String(format: "%06o", sum).utf8)
  b[154] = 0
  return b + data + [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
}

final class UstarTests: XCTestCase {
  func testIndependentUstarWithSplitPrefixThroughFileRead() throws {
    let fm = FileManager.default
    let exe = "/usr/bin/bsdtar"
    guard fm.isExecutableFile(atPath: exe) else {
      throw XCTSkip("bsdtar required for independent archive fixture")
    }
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = tmp.appendingPathComponent("src")
    let archive = tmp.appendingPathComponent("archive")
    let first = String(repeating: "long-", count: 13)
    let second = String(repeating: "sub-", count: 11)
    let nested = source.appendingPathComponent(first).appendingPathComponent(second)
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let bytes = (0..<3109).map { UInt8(truncatingIfNeeded: $0 * 31) }
    let file = "Case Sensitive.bin"
    try Data(bytes).write(to: nested.appendingPathComponent(file))
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: exe)
    tar.arguments = ["--format=ustar", "-cf", archive.path, "-C", source.path, "."]
    tar.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) {
      _, n in n
    }
    try tar.run()
    tar.waitUntilExit()
    XCTAssertEqual(tar.terminationStatus, 0)
    let v = try UstarVolume(Media(data: Array(try Data(contentsOf: archive))))
    let sub = try v.lookup(
      parent: v.lookup(parent: v.root, name: Array(first.utf8)), name: Array(second.utf8))
    let id = try v.lookup(parent: sub, name: Array(file.utf8))
    XCTAssertThrowsError(try v.lookup(parent: sub, name: Array(file.lowercased().utf8)))
    XCTAssertEqual(try v.bytes(node: id, offset: 503, count: 31), Array(bytes[503..<534]))
    throughServer(v, folders: [first, second], file: file, expected: bytes)
    readMountedMedia(v, node: id, expected: bytes)
  }

  func testImplicitDirectoriesAndByteExactUtf8Names() throws {
    let marked = "e\u{301}"
    let composed = "\u{e9}"
    let image =
      archiveRecord("a/" + marked, data: [1]) + archiveRecord("a/", type: 53) + archiveRecord("a/" + composed, data: [2])
      + endOfArchive
    let v = try UstarVolume(Media(data: image))
    let dir = try v.lookup(parent: 1, name: [97])
    XCTAssertEqual(try v.entry(parent: dir, index: 0)?.name.utf8.map { $0 }, Array(marked.utf8))
    XCTAssertNil(try v.entry(parent: dir, index: 2))
    let a = try v.lookup(parent: dir, name: Array(marked.utf8))
    let b = try v.lookup(parent: dir, name: Array(composed.utf8))
    XCTAssertNotEqual(a, b)
    XCTAssertEqual(try v.bytes(node: a, offset: 0, count: 2), [1])
    XCTAssertEqual(try v.bytes(node: b, offset: 0, count: 2), [2])
    XCTAssertEqual(try v.bytes(node: b, offset: .max, count: 2), [])
    XCTAssertThrowsError(try v.bytes(node: b, offset: 0, count: 1 << 21))
  }

  func testRejectsUnsafeNamesDuplicateEntriesAndSpecialFileTypes() {
    for name in ["/a", "../b", "a/../b", "a//b", "a/./b", "a/", "", "./", "line\nbreak"] {
      XCTAssertThrowsError(try UstarVolume(Media(data: archiveRecord(name) + endOfArchive)), name)
    }
    for type: UInt8 in [49, 50, 51, 52, 54, 55, 120, 103] {
      XCTAssertThrowsError(try UstarVolume(Media(data: archiveRecord("x", type: type) + endOfArchive)))
    }
    for records in [
      archiveRecord("a") + archiveRecord("a"), archiveRecord("a") + archiveRecord("a/b"),
      archiveRecord("a/b") + archiveRecord("a"), archiveRecord("a/", type: 53) + archiveRecord("a/", type: 53),
    ] {
      XCTAssertThrowsError(try UstarVolume(Media(data: records + endOfArchive)))
    }
  }

  func testBadSizeChecksumTruncationAndTrailingImagesFailMount() {
    let good = archiveRecord("x", data: [42])
    var corrupt = good
    corrupt[42] ^= 4
    let cases = [
      corrupt + endOfArchive, good + Array(endOfArchive.prefix(512)),
      good + endOfArchive + good, Array(good.prefix(512)) + endOfArchive,
      archiveRecord("d", type: 53, data: [42]) + endOfArchive,
      archiveRecord("x", adjust: { $0[124] = 0x80 }) + endOfArchive,
      archiveRecord("x", adjust: { $0[134] = 57 }) + endOfArchive,
      archiveRecord("x", adjust: { $0[157] = 97 }) + endOfArchive,
    ]
    for bytes in cases { XCTAssertThrowsError(try UstarVolume(Media(data: bytes))) }
    XCTAssertNoThrow(try UstarVolume(Media(data: endOfArchive)))
  }
}
