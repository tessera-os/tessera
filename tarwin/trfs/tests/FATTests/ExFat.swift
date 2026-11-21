import Foundation
import TarwinExFAT
import XCTest

private let filename = "Ω Long Binary File.bin"
private let contents = (0..<16409).map { UInt8(truncatingIfNeeded: $0 * 31 + 9) }
private func get(_ b: [UInt8], _ p: Int, _ n: Int) -> Int {
  b[p..<p + n].reversed().reduce(0) { $0 << 8 | Int($1) }
}
private func put(_ b: inout [UInt8], _ p: Int, _ n: Int, _ v: Int) {
  for i in 0..<n { b[p + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
}
private func checksumSet(_ b: inout [UInt8], _ p: Int) {
  var v = 0
  for j in 0..<(Int(b[p + 1]) + 1) * 32 where j != 2 && j != 3 {
    v = (((v >> 1) | ((v & 1) << 15)) + Int(b[p + j])) & 0xffff
  }
  put(&b, p + 2, 2, v)
}
private let exfatImage = Result<[UInt8], Error> {
  let fm = FileManager.default
  let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let src = tmp.appendingPathComponent("src")
  let sub = src.appendingPathComponent("Sub")
  let image = tmp.appendingPathComponent("test.cdr")
  guard fm.isExecutableFile(atPath: "/usr/bin/hdiutil") else {
    throw XCTSkip("hdiutil required for independent exFAT media")
  }
  try fm.createDirectory(at: sub, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: tmp) }
  try Data(contents).write(to: sub.appendingPathComponent(filename))
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
  p.arguments = [
    "create", "-quiet", "-size", "24m", "-volname", "TEST", "-fs", "ExFAT", "-layout", "NONE",
    "-srcfolder", src.path, "-format", "UDTO", image.path,
  ]
  try p.run()
  p.waitUntilExit()
  guard p.terminationStatus == 0 else {
    throw NSError(domain: "hdiutil", code: Int(p.terminationStatus))
  }
  return Array(try Data(contentsOf: image))
}
private struct Layout {
  let sector: Int, unit: Int, heap: Int, fat: Int, total: Int, root: Int, bitmap: Int, table: Int,
    stream: Int
  init(_ b: [UInt8]) throws {
    sector = 1 << Int(b[108])
    unit = sector << Int(b[109])
    heap = get(b, 88, 4) * sector
    fat = get(b, 80, 4) * sector
    total = get(b, 92, 4)
    let h = heap
    let u = unit
    func data(_ c: Int) -> Int { h + (c - 2) * u }
    root = data(get(b, 96, 4))
    let records = stride(from: root, to: root + unit, by: 32).prefix(while: { b[$0] != 0 })
    bitmap = data(get(b, try XCTUnwrap(records.first(where: { b[$0] == 0x81 })) + 20, 4))
    table = data(get(b, try XCTUnwrap(records.first(where: { b[$0] == 0x82 })) + 20, 4))
    let dir = try XCTUnwrap(records.first(where: { b[$0] == 0x85 && b[$0 + 64 + 2] == 83 }))
    let sub = data(get(b, dir + 32 + 20, 4))
    stream =
      try XCTUnwrap(
        stride(from: sub, to: sub + unit, by: 32).first(where: {
          b[$0] == 0x85 && b[$0 + 64 + 2] == 0xa9
        })) + 32
  }
  func data(_ c: Int) -> Int { heap + (c - 2) * unit }
}

final class ExFatTests: XCTestCase {
  func testIndependentExFatThroughMountedReadAndVolumeCaseMapping() throws {
    let v = try ExFatVolume(Media(data: exfatImage.get()))
    let folder = try v.lookup(parent: v.root, name: Array("sub".utf8))
    let id = try v.lookup(parent: folder, name: Array(filename.lowercased().utf8))
    XCTAssertEqual(try v.node(id).name, filename)
    XCTAssertThrowsError(try v.lookup(parent: folder, name: Array("../".utf8)))
    XCTAssertEqual(try v.bytes(node: id, offset: 4041, count: 3300), Array(contents[4041..<7341]))
    throughServer(v, folders: ["sUB"], file: filename.lowercased(), expected: contents)
    readMountedMedia(v, node: id, expected: contents)
  }
  func testFragmentedChainAndUninitializedTailAreNotAContiguousMediaRead() throws {
    var b = try exfatImage.get()
    let l = try Layout(b)
    let s = l.stream
    let first = get(b, s + 20, 4)
    let n = (contents.count + l.unit - 1) / l.unit
    XCTAssertEqual(b[s + 1], 3)
    guard n >= 2 else { return XCTFail("Need multiple data clusters") }
    let new = try XCTUnwrap(
      (2..<(l.total + 2)).reversed().first(where: { c in
        b[l.bitmap + (c - 2) / 8] & (1 << ((c - 2) % 8)) == 0
      }))
    var chain = Array(first..<(first + n))
    chain[1] = new
    let old = l.data(first + 1)
    let dest = l.data(new)
    let valid = l.unit + 19
    let copy = Array(b[old..<old + l.unit])
    b.replaceSubrange(dest..<dest + l.unit, with: copy)
    b.replaceSubrange(old..<old + l.unit, with: repeatElement(0xe2, count: l.unit))
    b[l.bitmap + (new - 2) / 8] |= 1 << ((new - 2) % 8)
    b[l.bitmap + (first - 1) / 8] &= ~(1 << ((first - 1) % 8))
    for (i, c) in chain.enumerated() {
      put(&b, l.fat + 4 * c, 4, i + 1 < n ? chain[i + 1] : 0xffff_ffff)
    }
    b[s + 1] = 1
    put(&b, s + 8, 8, valid)
    checksumSet(&b, s - 32)
    let v = try ExFatVolume(Media(data: b))
    let folder = try v.lookup(parent: 1, name: Array("Sub".utf8))
    let id = try v.lookup(parent: folder, name: Array(filename.utf8))
    let expected =
      Array(contents.prefix(valid)) + Array(repeating: UInt8(0), count: contents.count - valid)
    XCTAssertEqual(
      try v.bytes(node: id, offset: UInt64(l.unit - 2), count: 23),
      Array(expected[(l.unit - 2)..<(l.unit + 21)]))
    readMountedMedia(v, node: id, expected: expected)
    put(&b, l.fat + 4 * new, 4, first)
    XCTAssertThrowsError(try ExFatVolume(Media(data: b)))
  }
  func testCorruptionFailsBeforePublishingTheRoot() throws {
    let base = try exfatImage.get()
    let l = try Layout(base)
    let s = l.stream
    func reject(
      _ mutate: (inout [UInt8]) -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
      var b = base
      mutate(&b)
      XCTAssertThrowsError(try ExFatVolume(Media(data: b)), file: file, line: line)
    }
    reject { $0[106] |= 2 }
    reject { $0[11 * l.sector] ^= 4 }
    reject { $0[23 * l.sector + 4] ^= 8 }
    reject { $0[l.table + 6] ^= 1 }
    reject { $0[s - 30] ^= 16 }
    reject { b in
      let bit = get(b, s + 20, 4) - 2
      b[l.bitmap + bit / 8] &= ~(1 << (bit % 8))
    }
    reject { b in
      put(&b, s + 20, 4, get(base, 96, 4))
      checksumSet(&b, s - 32)
    }
    reject { b in
      b[s + 4] ^= 16
      checksumSet(&b, s - 32)
    }
    reject { b in
      put(&b, s + 8, 8, contents.count + 1)
      checksumSet(&b, s - 32)
    }
    reject { b in
      b[s + 32 + 2] = 47
      checksumSet(&b, s - 32)
    }
  }
}
