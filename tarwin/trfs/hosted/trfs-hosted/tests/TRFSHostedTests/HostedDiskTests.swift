import Darwin
import TRFS
import TarwinBlockHosted
import XCTest

@testable import TRFSHosted

final class HostedDiskTests: XCTestCase {
  var dir = ""
  override func setUp() { dir = tempDir() }
  override func tearDown() { removeTree(dir) }

  func testFirstStartFormatsThenRemountsWithData() throws {
    let path = try HostedTrfsDisk.imagePath(name: "Data", home: dir)
    XCTAssertTrue(path.hasSuffix("/Library/Application Support/Tessera/Disks/Data.trfs"))
    var file: UInt64 = 0
    do {
      let disk = try HostedTrfsDisk.openData(path: path, blocks: 1 << 16)
      file = try XCTUnwrap(disk.withVolume { $0.create(1, name: Array("hello".utf8), kind: .file) })
      let text = Array("hello from tarwind".utf8)
      XCTAssertTrue(disk.withVolume { v in
        text.withUnsafeBytes { v.writePage(file, index: 0, bytes: $0) }
      })
    }
    let disk = try HostedTrfsDisk.openData(path: path, blocks: 1 << 16)
    let out = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 16)
    defer { out.deallocate() }
    let n = disk.withVolume { v -> Int? in
      guard let root = v.snapshot,
        case .file(let id) = v.lookup(1, name: Array("hello".utf8), in: root), id == file
      else { return nil }
      return v.readPage(file, index: 0, in: root, into: out)
    }
    XCTAssertEqual(n, 18)
    XCTAssertEqual(String(decoding: out.prefix(18), as: UTF8.self), "hello from tarwind")
    var st = stat()
    stat(path, &st)
    XCTAssertEqual(st.st_size, 1 << 28)
    XCTAssertLessThan(Int(st.st_blocks) * 512, 4 << 20, "disk stays sparse")
  }

  func testDamagedImageIsNeverReformatted() throws {
    let path = dir + "/bad.trfs"
    _ = try HostedBlockDevice.create(path: path, blocks: 64)
    XCTAssertThrowsError(try HostedTrfsDisk.openData(path: path, blocks: 64)) {
      XCTAssertEqual($0 as? HostedTrfsError, .mount)
    }
    let d = try HostedBlockDevice.open(path: path)
    let p = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 16)
    defer { p.deallocate() }
    XCTAssertTrue(d.read(0, into: p))
    XCTAssertTrue(p.allSatisfy { $0 == 0 }, "anchor left untouched")
  }

  func testSecondTarwindIsLockedOut() throws {
    let path = dir + "/d.trfs"
    let a = try HostedTrfsDisk.openData(path: path, blocks: 64)
    XCTAssertThrowsError(try HostedTrfsDisk.openData(path: path, blocks: 64)) {
      XCTAssertEqual($0 as? HostedTrfsError, .disk(.locked))
    }
    _ = a
  }

  func testSystemMountFailsClosed() throws {
    let path = dir + "/sys.trfs"
    var head: TrfsDigest?
    do {
      let d = try HostedTrfsDisk.openData(path: path, blocks: 64)
      _ = d.withVolume { $0.create(1, name: Array("bin".utf8), kind: .directory) }
      head = d.withVolume { $0.snapshot?.digest }
    }
    var raw = [UInt8](repeating: 0, count: 32)
    XCTAssertTrue(raw.withUnsafeMutableBytes { head!.encode(into: $0) })
    var measured: [TrfsDigest] = []
    let ok = try raw.withUnsafeBytes { r in
      try HostedTrfsDisk.openSystem(path: path, bootSetRoot: r) { measured.append($0); return true }
    }
    XCTAssertNotNil(ok.withVolume { $0.snapshot })
    XCTAssertEqual(measured, [head!])
    withExtendedLifetime(ok) {}
  }

  func testSystemMountRejectsBadRootAndFailedMeasurement() throws {
    let path = dir + "/sys.trfs"
    var raw = [UInt8](repeating: 0, count: 32)
    do {
      let d = try HostedTrfsDisk.openData(path: path, blocks: 64)
      _ = d.withVolume { $0.create(1, name: Array("bin".utf8), kind: .directory) }
      XCTAssertTrue(raw.withUnsafeMutableBytes { d.withVolume { $0.snapshot! }.digest.encode(into: $0) })
    }
    XCTAssertThrowsError(try raw.withUnsafeBytes { r in
      try HostedTrfsDisk.openSystem(path: path, bootSetRoot: r) { _ in false }
    })
    XCTAssertThrowsError(try raw.withUnsafeBytes { r in
      try HostedTrfsDisk.openSystem(path: path, bootSetRoot: .init(rebasing: r[0..<31])) { _ in true }
    })
    raw[0] ^= 1
    XCTAssertThrowsError(try raw.withUnsafeBytes { r in
      try HostedTrfsDisk.openSystem(path: path, bootSetRoot: r) { _ in true }
    })
  }
}
