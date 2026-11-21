import Foundation
import TarwinFAT
import XCTest

struct Media: FatMedia {
  var data: [UInt8]
  var byteCount: UInt64 { UInt64(data.count) }
  func read(at: UInt64, count: Int) -> [UInt8]? {
    guard at <= byteCount, UInt64(count) <= byteCount - at else { return nil }
    return Array(data[Int(at)..<(Int(at) + count)])
  }
}
private let sector = 512
private let root = 35 * 512
private let first = 36 * 512
func sample() -> Media {
  var b = [UInt8](repeating: 0, count: 4200 * 512)
  func put(_ p: Int, _ v: Int) {
    b[p] = UInt8(truncatingIfNeeded: v)
    b[p + 1] = UInt8(truncatingIfNeeded: v >> 8)
  }
  b[510] = 0x55
  b[511] = 0xaa
  put(11, 512)
  b[13] = 1
  put(14, 1)
  b[16] = 2
  put(17, 16)
  put(19, 4200)
  b[21] = 0xf8
  put(22, 17)
  for p in [512, 18 * 512] {
    put(p, 0xfff8)
    put(p + 2, 0xffff)
    put(p + 4, 4)
    put(p + 8, 0xfff8)
  }
  b.replaceSubrange(root..<(root + 11), with: "README  TXT".utf8)
  b[root + 11] = 32
  put(root + 26, 2)
  put(root + 28, 518)
  b[first + 511] = 44
  b.replaceSubrange((first + 1024)..<(first + 1030), with: [1, 2, 3, 4, 5, 6])
  return Media(data: b)
}
final class VolumeTests: XCTestCase {
  func testFragmentedReadStopsAtEndAndRejectsPaths() throws {
    let v = try FatVolume(sample())
    let file = try v.lookup(parent: v.root, name: Array("readme.txt".utf8))
    XCTAssertThrowsError(try v.lookup(parent: v.root, name: Array("../README.TXT".utf8)))
    XCTAssertThrowsError(try v.lookup(parent: v.root, name: Array(".".utf8)))
    XCTAssertThrowsError(try v.lookup(parent: file, name: [65]))
    XCTAssertEqual(try v.bytes(node: file, offset: 511, count: 100), [44, 1, 2, 3, 4, 5, 6])
    XCTAssertEqual(try v.bytes(node: file, offset: .max, count: 1), [])
    XCTAssertThrowsError(try v.bytes(node: file, offset: 0, count: 1 << 21))
  }
  func testBadChainsCopiesAndDirectoriesFailBeforeRootIsExposed() {
    for (at, value) in [
      (18 * sector + 4, 9), (root + 26, 0), (root + 28, 0), (510, 0), (22, 1), (13, 3),
    ] {
      var m = sample()
      m.data[at] = UInt8(value)
      if at == root + 28 { m.data[at + 1] = 0 }
      XCTAssertThrowsError(try FatVolume(m))
    }
    for next in [2, 0, 0xfff7, 0xfff0, 0xfff8] {
      var m = sample()
      for p in [512, 18 * 512] {
        m.data[p + 4] = UInt8(truncatingIfNeeded: next)
        m.data[p + 5] = UInt8(next >> 8)
      }
      XCTAssertThrowsError(try FatVolume(m))
    }
    var crossed = sample()
    crossed.data.replaceSubrange(
      (root + 32)..<(root + 64), with: Array(crossed.data[root..<(root + 32)]))
    crossed.data[root + 32] = 65
    XCTAssertThrowsError(try FatVolume(crossed))
  }
  func testMtoolsFormattedImage() throws { try mtoolsImage(wide: false) }
  func testMtoolsFormattedFAT32Image() throws { try mtoolsImage(wide: true) }
  private func mtoolsImage(wide: Bool) throws {
    let fm = FileManager.default
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    guard
      let bin = path.split(separator: ":").first(where: {
        fm.isExecutableFile(atPath: "\($0)/mformat")
      })
    else { throw XCTSkip("mtools required for independent media fixture") }
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: dir) }
    let img = dir.appendingPathComponent("disk").path
    let source = dir.appendingPathComponent("original")
    let data = Data((0..<9216).map { UInt8(truncatingIfNeeded: $0 * 31) })
    try data.write(to: source)
    func run(_ name: String, _ args: [String]) throws {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "\(bin)/\(name)")
      p.arguments = ["-i", img] + args
      try p.run()
      p.waitUntilExit()
      guard p.terminationStatus == 0 else { throw FatError.io }
    }
    let geometry = wide ? ["-F", "-T", "73728"] : ["-h", "8", "-n", "32", "-t", "64"]
    try run("mformat", ["-C"] + geometry + ["-c", "1", "::"])
    try run("mmd", ["::/DOCS"])
    try run("mcopy", [source.path, "::/DOCS/NOTES.TXT"])
    let v = try FatVolume(Media(data: Array(try Data(contentsOf: URL(fileURLWithPath: img)))))
    let docs = try v.lookup(parent: v.root, name: Array("docs".utf8))
    let file = try v.lookup(parent: docs, name: Array("notes.txt".utf8))
    XCTAssertEqual(try v.bytes(node: file, offset: 0, count: 10000), Array(data))
    throughServer(v, folders: ["docs"], file: "notes.txt", expected: Array(data))
    readMountedMedia(v, node: file, expected: Array(data))
  }
}
