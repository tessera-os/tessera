import Darwin
import TarwinBlockWire
import XCTest

@testable import TarwinBlockHosted

final class HostedBlockTests: XCTestCase {
  var dir = ""
  override func setUp() {
    var t = Array("/tmp/h4blk.XXXXXX".utf8CString)
    dir = String(cString: mkdtemp(&t))
  }
  override func tearDown() { removeTree(dir) }

  func page(_ b: UInt8) -> UnsafeMutableRawBufferPointer {
    let p = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 16)
    p.initializeMemory(as: UInt8.self, repeating: b)
    return p
  }

  func testCreateIsSparseZeroAndExclusive() throws {
    let path = dir + "/d.img"
    let d = try HostedBlockDevice.create(path: path, blocks: 1 << 18)  // 1 GiB
    XCTAssertEqual(d.blocks, 1 << 18)
    var st = stat()
    stat(path, &st)
    XCTAssertEqual(st.st_size, 1 << 30)
    XCTAssertLessThan(Int(st.st_blocks) * 512, 1 << 20, "image must be sparse")
    let p = page(7)
    defer { p.deallocate() }
    XCTAssertTrue(d.read(1000, into: p))
    XCTAssertTrue(p.allSatisfy { $0 == 0 })
    XCTAssertThrowsError(try HostedBlockDevice.create(path: path, blocks: 8)) {
      XCTAssertEqual($0 as? HostedDiskError, .exists)
    }
    XCTAssertThrowsError(try HostedBlockDevice.open(path: path)) {
      XCTAssertEqual($0 as? HostedDiskError, .locked)
    }
  }

  func testWriteFlushReopen() throws {
    let path = dir + "/d.img"
    do {
      let d = try HostedBlockDevice.create(path: path, blocks: 16)
      let p = page(0xA5)
      defer { p.deallocate() }
      XCTAssertTrue(d.write(15, from: .init(p)))
      XCTAssertFalse(d.write(16, from: .init(p)), "past end")
      XCTAssertFalse(d.write(3, from: .init(rebasing: p[0..<512])), "partial block")
      XCTAssertTrue(d.flush())
    }
    let d = try HostedBlockDevice.open(path: path)
    let p = page(0)
    defer { p.deallocate() }
    XCTAssertTrue(d.read(15, into: p))
    XCTAssertTrue(p.allSatisfy { $0 == 0xA5 })
    XCTAssertTrue(d.discard(15, count: 1))
    XCTAssertTrue(d.read(15, into: p))
    XCTAssertTrue(p.allSatisfy { $0 == 0 })
  }

  func testOpenRejectsBadGeometryAndSymlink() throws {
    let path = dir + "/odd.img"
    let fd = open(path, O_RDWR | O_CREAT, 0o600)
    ftruncate(fd, 4096 * 4 + 1)
    close(fd)
    XCTAssertThrowsError(try HostedBlockDevice.open(path: path)) {
      XCTAssertEqual($0 as? HostedDiskError, .badGeometry)
    }
    symlink(path, dir + "/link.img")
    XCTAssertThrowsError(try HostedBlockDevice.open(path: dir + "/link.img"))
    XCTAssertThrowsError(try HostedBlockDevice.open(path: dir + "/none.img")) {
      XCTAssertEqual($0 as? HostedDiskError, .notFound)
    }
  }

  func testReadOnlyRefusesWrites() throws {
    let path = dir + "/d.img"
    _ = try HostedBlockDevice.create(path: path, blocks: 8)
    let d = try HostedBlockDevice.open(path: path, readOnly: true)
    let p = page(1)
    defer { p.deallocate() }
    XCTAssertFalse(d.write(0, from: .init(p)))
    XCTAssertFalse(d.flush())
    XCTAssertTrue(d.read(0, into: p))
  }

  func testDisksDirectory() throws {
    let d = try HostedBlockDevice.disksDirectory(home: dir)
    XCTAssertEqual(d, dir + "/Library/Application Support/Tessera/Disks")
    var st = stat()
    XCTAssertEqual(stat(d, &st), 0)
  }

  func testDriverServesProtocol() throws {
    let dev = try HostedBlockDevice.create(path: dir + "/d.img", blocks: 64)
    let drv = HostedBlockDriver(device: dev)
    let mem = UnsafeMutableRawBufferPointer.allocate(byteCount: 3 * 4096, alignment: 16)
    defer { mem.deallocate() }
    for i in 0..<mem.count { mem[i] = UInt8(truncatingIfNeeded: i / 4096 + 1) }
    let vecs = [BlockDmaVector(address: 0x10000, bytes: 4096),
                BlockDmaVector(address: 0x20000, bytes: 8192)]
    var mapped: [(UInt64, Bool)] = []
    let map: HostedBlockDriver.Map = { a, n, w in
      mapped.append((a, w))
      let off = a == 0x10000 ? 0 : 4096
      return UnsafeMutableRawBufferPointer(rebasing: mem[off..<(off + Int(n))])
    }
    let pay = BlockPayload(list: 0x8000, vectors: 2)
    let w = BlockRequest(id: 1, epoch: 1, lba: 10, blocks: 3, queue: 0, op: .fua,
      qos: .standard, payload: pay)!
    XCTAssertEqual(vecs.withUnsafeBufferPointer { drv.serve(w, vectors: $0, map: map) }.status, .ok)
    XCTAssertEqual(mapped.map(\.1), [false, false], "device reads memory on write")
    mem.initializeMemory(as: UInt8.self, repeating: 0)
    let r = BlockRequest(id: 2, epoch: 1, lba: 10, blocks: 3, queue: 0, op: .read,
      qos: .standard, payload: pay)!
    XCTAssertEqual(vecs.withUnsafeBufferPointer { drv.serve(r, vectors: $0, map: map) }.status, .ok)
    XCTAssertEqual([mem[0], mem[4096], mem[8192]], [1, 2, 3])
    let big = BlockRequest(id: 3, epoch: 1, lba: 62, blocks: 3, queue: 0, op: .read,
      qos: .standard, payload: pay)!
    XCTAssertEqual(
      vecs.withUnsafeBufferPointer { drv.serve(big, vectors: $0, map: map) }.status, .unsupported)
    let refused: HostedBlockDriver.Map = { _, _, _ in nil }
    XCTAssertEqual(
      vecs.withUnsafeBufferPointer { drv.serve(r, vectors: $0, map: refused) }.status, .unsupported)
    let f = BlockRequest(id: 4, epoch: 1, lba: 0, blocks: 0, queue: 0, op: .flush,
      qos: .standard, payload: .init())!
    XCTAssertEqual(drv.serve(f, vectors: .init(start: nil, count: 0), map: map).status, .ok)
  }
}

func removeTree(_ path: String) {
  if let d = opendir(path) {
    while let e = readdir(d) {
      let name = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
      if name == "." || name == ".." { continue }
      removeTree(path + "/" + name)
    }
    closedir(d)
    rmdir(path)
  } else {
    unlink(path)
  }
}
