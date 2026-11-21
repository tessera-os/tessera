import CryptoKit
import Foundation
import XCTest

@testable import TRFS

private let zero = Data(repeating: 0, count: 4096)
private final class Disk: TrfsMedia {
  let blocks: UInt64
  var stable, live: [Data]
  var cuts = [[Data]](), trace = false, refuseFlush = false
  var unreadable: UInt64?
  init(_ cells: [Data] = Array(repeating: zero, count: 48)) {
    stable = cells
    live = cells
    blocks = UInt64(cells.count)
  }
  func read(_ block: UInt64, into dst: UnsafeMutableRawBufferPointer) -> Bool {
    guard block < blocks, block != unreadable, dst.count == 4096 else { return false }
    live[Int(block)].copyBytes(to: dst)
    return true
  }
  func write(_ block: UInt64, from src: UnsafeRawBufferPointer) -> Bool {
    guard block < blocks, src.count == 4096 else { return false }
    let i = Int(block)
    live[i] = Data(src)
    if trace {
      var torn = stable
      torn[i].replaceSubrange(..<512, with: live[i].prefix(512))
      cuts += [stable, torn, live]
    }
    return true
  }
  func flush() -> Bool {
    if trace { cuts += [stable, live] }
    guard !refuseFlush else { return false }
    stable = live
    return true
  }
  func sha256(_ b: UnsafeRawBufferPointer) -> TrfsDigest {
    SHA256.hash(data: Data(b)).withUnsafeBytes { TrfsDigest($0)! }
  }
}

private final class Frames: TrfsSnapshotFrames {
  let inode: UInt64
  let page = UnsafeMutableRawBufferPointer.allocate(byteCount: 16384, alignment: 16384)
  init(_ inode: UInt64) { self.inode = inode }
  deinit { page.deallocate() }
  func file(for object: UInt64) -> UInt64? { object == 99 ? inode : nil }
  func mayWrite(_ object: UInt64) -> Bool { object == 99 }
  func acquire(_ bytes: UInt64) -> UInt64? { bytes == 16384 ? 0x4000 : nil }
  func mapping(_ physical: UInt64) -> UnsafeMutableRawBufferPointer? {
    physical == 0x4000 ? page : nil
  }
  func release(_ physical: UInt64, bytes: UInt64) {
    page.initializeMemory(as: UInt8.self, repeating: 0)
  }
}
final class SnapshotVolumeTests: XCTestCase {
  let a: [UInt8] = [97], b: [UInt8] = [98]
  let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 8)
  let out = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 8)
  deinit {
    scratch.deallocate()
    out.deallocate()
  }

  func testLinksStayRelativeToTheAuthorizedNodeAndSnapshot() throws {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    let disk = Disk()
    var v = TrfsVolume(media: disk, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let dir = try XCTUnwrap(v.create(1, name: a, kind: .directory))
    let child = try XCTUnwrap(v.create(dir, name: b, kind: .directory))
    let file = try XCTUnwrap(v.create(dir, name: bytes("file"), kind: .file))
    let link = try XCTUnwrap(v.createSymlink(child, name: a, target: bytes("../file")))
    _ = try XCTUnwrap(v.createSymlink(dir, name: bytes("step"), target: bytes("./b")))
    let old = try XCTUnwrap(v.snapshot)
    let path = bytes("step/a")
    XCTAssertEqual(v.resolve(from: dir, relative: path, followLinks: true, in: old), .found(file))
    XCTAssertEqual(v.resolve(from: child, relative: a, followLinks: true, in: old), .escape)
    XCTAssertEqual(v.resolve(from: dir, relative: path, followLinks: false, in: old), .notDirectory)
    XCTAssertNil(v.length(link, in: old))
    XCTAssertTrue(v.moveFile(child, name: a, to: dir, as: bytes("moved")))
    XCTAssertEqual(v.resolve(from: dir, relative: bytes("moved"), followLinks: true,
      in: v.snapshot!), .escape)
    XCTAssertTrue(v.unlinkFile(dir, name: bytes("moved")))
    XCTAssertEqual(v.lookup(dir, name: bytes("file"), in: v.snapshot!), .file(file))
    _ = try XCTUnwrap(v.createSymlink(child, name: a, target: a))
    XCTAssertEqual(v.resolve(from: child, relative: a, followLinks: true, in: v.snapshot!), .loop)
    XCTAssertTrue(v.branch(from: old))
    var pinned = TrfsVolume(media: disk, scratch: scratch)!
    XCTAssertTrue(pinned.mount(expected: old.digest))
    XCTAssertEqual(pinned.resolve(from: dir, relative: path, followLinks: true, in: old),
      .found(file))
    XCTAssertNil(pinned.createSymlink(dir, name: bytes("another"), target: b))
  }

  func testLinkCommitCrashCutsAndTargetIntegrity() throws {
    let disk = Disk()
    var v = TrfsVolume(media: disk, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let file = try XCTUnwrap(v.create(1, name: a, kind: .file))
    for invalid: [UInt8] in [[], [47, 97], [97, 47], [97, 0], [97, 47, 47, 98],
      Array(repeating: 97, count: 256), Array(repeating: 97, count: 4097)] {
      XCTAssertNil(v.createSymlink(1, name: b, target: invalid))
    }
    XCTAssertNil(v.create(1, name: b, kind: .symlink))
    disk.trace = true
    let id = try XCTUnwrap(v.createSymlink(1, name: b, target: a))
    let root = try XCTUnwrap(v.snapshot)
    var absent = false, present = false
    for cut in disk.cuts {
      var read = TrfsVolume(media: Disk(cut), scratch: scratch)!
      XCTAssertTrue(read.mount())
      switch read.resolve(from: 1, relative: b, followLinks: true, in: read.snapshot!) {
      case .found(file): present = true
      case .notFound: absent = true
      default: XCTFail("torn link")
      }
    }
    XCTAssertTrue(absent && present)
    disk.live[Int(id - 1)][0] ^= 1
    XCTAssertEqual(v.resolve(from: 1, relative: b, followLinks: true, in: root), .damaged)
    XCTAssertEqual(v.lookup(1, name: a, in: root), .file(file))
  }

  func testAllWriteAndFlushCutsOfRenameGiveExactlyOneName() throws {
    let disk = Disk()
    var v = TrfsVolume(media: disk, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let file = try XCTUnwrap(v.create(1, name: a, kind: .file))
    disk.trace = true
    XCTAssertTrue(v.moveFile(1, name: a, to: 1, as: b))
    XCTAssertEqual(disk.cuts.count, 13)  // 3 writes with 3 cuts each, 2 barriers with 2 each
    var old = false
    var new = false
    for image in disk.cuts {
      let d = Disk(image)
      var reopened = TrfsVolume(media: d, scratch: scratch)!
      XCTAssertTrue(reopened.mount())
      let root = try XCTUnwrap(reopened.snapshot)
      switch (reopened.lookup(1, name: a, in: root), reopened.lookup(1, name: b, in: root)) {
      case (.file(file), .absent): old = true
      case (.absent, .file(file)): new = true
      default: XCTFail("rename exposed a hybrid namespace")
      }
    }
    XCTAssertTrue(old && new)
  }

  func testWriteCrashCutsPreserveWholeDataAndSize() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let file = try XCTUnwrap(v.create(1, name: a, kind: .file))
    XCTAssertTrue(Data([11]).withUnsafeBytes { v.writePage(file, index: 0, bytes: $0) })
    d.trace = true
    XCTAssertTrue(
      Data(repeating: 33, count: 4096).withUnsafeBytes { v.writePage(file, index: 0, bytes: $0) })
    XCTAssertEqual(d.cuts.count, 16)
    for image in d.cuts {
      var r = TrfsVolume(media: Disk(image), scratch: scratch)!
      XCTAssertTrue(r.mount())
      let n = try XCTUnwrap(r.readPage(file, index: 0, in: r.snapshot!, into: out))
      if n == 1 {
        XCTAssertEqual(out[0], 11)
        XCTAssertTrue(out.dropFirst().allSatisfy { $0 == 0 })
      } else {
        XCTAssertEqual(n, 4096)
        XCTAssertTrue(out.allSatisfy { $0 == 33 })
      }
    }
  }

  func testBranchPinsOldBytesAndVerifiedMountRefusesMutations() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let dir = try XCTUnwrap(v.create(1, name: a, kind: .directory))
    let file = try XCTUnwrap(v.create(dir, name: b, kind: .file))
    let contents = Data([7, 8, 9])
    XCTAssertTrue(contents.withUnsafeBytes { v.writePage(file, index: 1, bytes: $0) })
    let old = v.snapshot!
    XCTAssertTrue(v.unlinkFile(dir, name: b))
    let unlinked = v.snapshot!
    XCTAssertEqual(v.lookup(dir, name: b, in: unlinked), .absent)
    XCTAssertTrue(v.branch(from: old))
    XCTAssertEqual(v.lookup(dir, name: b, in: v.snapshot!), .file(file))
    XCTAssertEqual(v.readPage(file, index: 0, in: old, into: out), 4096)
    XCTAssertTrue(out.allSatisfy { $0 == 0 })
    XCTAssertEqual(v.readPage(file, index: 1, in: old, into: out), 3)
    XCTAssertEqual(Data(out.prefix(3)), contents)
    XCTAssertEqual(v.readPage(file, index: 2, in: old, into: out), 0)
    // Persist an actual disk image and reopen without any allocator state.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try d.stable.reduce(into: Data()) { $0.append($1) }.write(to: url)
    let bytes = try Data(contentsOf: url)
    let cells = stride(from: 0, to: bytes.count, by: 4096).map {
      bytes.subdata(in: $0..<($0 + 4096))
    }
    let disk = Disk(cells)
    var boot = TrfsVolume(media: disk, scratch: scratch)!
    XCTAssertFalse(boot.mount(expected: unlinked.digest))
    XCTAssertTrue(boot.mount(expected: old.digest))
    XCTAssertNil(boot.create(dir, name: a, kind: .file))
    XCTAssertFalse(boot.branch(from: old))
    XCTAssertEqual(boot.lookup(dir, name: b, in: old), .file(file))
    XCTAssertEqual(boot.lookup(dir, name: b, in: unlinked), .damaged)
    XCTAssertNil(boot.readPage(file, index: 1, in: unlinked, into: out))
    let frames = Frames(file)
    withUnsafePointer(to: &boot) { pointer in
      let store = TrfsSnapshotStore(volume: pointer, root: old, frames: frames)
      XCTAssertFalse(store.mayFault(object: 99, write: true))
      XCTAssertFalse(store.mayFault(object: file, write: false))
      XCTAssertFalse(store.load(object: 99, offset: 0, valid: 4096, into: 0x4000))
      XCTAssertTrue(store.load(object: 99, offset: 0, valid: 4099, into: 0x4000))
      XCTAssertEqual(Data(frames.page[4096..<4099]), contents)
    }
  }

  func testMutableFrameHasOneCommitAndRejectsStaleBindings() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let file = try XCTUnwrap(v.create(1, name: a, kind: .file))
    XCTAssertTrue(Data([1]).withUnsafeBytes { v.writePage(file, index: 3, bytes: $0) })
    let old = try XCTUnwrap(v.snapshot)
    let frames = Frames(file)
    try withUnsafeMutablePointer(to: &v) { ptr in
      var mount = try XCTUnwrap(TrfsSnapshotStore(writer: ptr, frames: frames))
      var stale = try XCTUnwrap(TrfsSnapshotStore(writer: ptr, frames: frames))
      XCTAssertTrue(mount.load(object: 99, offset: 0, valid: 12289, into: 0x4000))
      frames.page.initializeMemory(as: UInt8.self, repeating: 0x63)
      XCTAssertFalse(mount.store(object: file, offset: 0, valid: 12289, from: 0x4000))
      XCTAssertFalse(mount.store(object: 99, offset: 0, valid: 16384, from: 0x4000))
      d.trace = true
      XCTAssertTrue(mount.store(object: 99, offset: 0, valid: 12289, from: 0x4000))
      XCTAssertFalse(stale.mayFault(object: 99, write: true))
      XCTAssertFalse(stale.store(object: 99, offset: 0, valid: 12289, from: 0x4000))
      XCTAssertTrue(mount.mayFault(object: 99, write: true))
    }
    let current = try XCTUnwrap(v.snapshot)
    for image in d.cuts {
      var m = TrfsVolume(media: Disk(image), scratch: scratch)!
      XCTAssertTrue(m.mount())
      let root = try XCTUnwrap(m.snapshot)
      XCTAssertTrue(root == old || root == current)
      for index in UInt64(0)...3 {
        let count = index == 3 ? 1 : 4096
        XCTAssertEqual(m.readPage(file, index: index, in: root, into: out), count)
        let expected: UInt8 = root == current ? 0x63 : index == 3 ? 1 : 0
        XCTAssertTrue(out.prefix(count).allSatisfy { $0 == expected })
        XCTAssertTrue(out.dropFirst(count).allSatisfy { $0 == 0 })
      }
    }
    let raw = UnsafeMutableRawBufferPointer(rebasing: out[..<32])
    XCTAssertTrue(current.digest.encode(into: raw))
    let diskRoot = try XCTUnwrap(TrfsDigest(.init(raw)))
    var boot = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(boot.mount(expected: diskRoot))
    withUnsafeMutablePointer(to: &boot) {
      XCTAssertNil(TrfsSnapshotStore(writer: $0, frames: frames))
    }
  }

  func testSystemMountMeasuresOnlyTheVerifiedHeadAndNeverRetriesAnUncertainExtend() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    _ = try XCTUnwrap(v.create(1, name: a, kind: .file))
    let older = try XCTUnwrap(v.snapshot)
    _ = try XCTUnwrap(v.create(1, name: b, kind: .file))
    let root = try XCTUnwrap(v.snapshot)
    var mismatch = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertFalse(mismatch.mountSystem(expected: older.digest) { _ in XCTFail(); return true })
    XCTAssertNil(mismatch.snapshot)
    var fenced = TrfsVolume(media: d, scratch: scratch)!
    var extended = [TrfsDigest]()
    XCTAssertFalse(fenced.mountSystem(expected: root.digest) { extended.append($0); return false })
    XCTAssertNil(fenced.snapshot)
    XCTAssertFalse(fenced.mountSystem(expected: root.digest) { extended.append($0); return true })
    XCTAssertFalse(fenced.mount())
    XCTAssertFalse(fenced.formatBlank())
    var clean = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(clean.mountSystem(expected: root.digest) { extended.append($0); return true })
    XCTAssertEqual(extended, [root.digest, root.digest])
    XCTAssertEqual(clean.snapshot, root)
    XCTAssertNil(clean.create(1, name: [99], kind: .file))
  }

  func testRestoringSameRootDoesNotRestoreWritableBinding() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let file = try XCTUnwrap(v.create(1, name: a, kind: .file))
    XCTAssertTrue(Data([3]).withUnsafeBytes { v.writePage(file, index: 0, bytes: $0) })
    let original = try XCTUnwrap(v.snapshot)
    let frames = Frames(file)
    try withUnsafeMutablePointer(to: &v) { ptr in
      var first = try XCTUnwrap(TrfsSnapshotStore(writer: ptr, frames: frames))
      XCTAssertTrue(ptr.pointee.branch(from: original))
      XCTAssertEqual(ptr.pointee.snapshot, original)
      XCTAssertFalse(first.mayFault(object: 99, write: false))
      XCTAssertFalse(first.load(object: 99, offset: 0, valid: 1, into: 0x4000))
      XCTAssertFalse(first.store(object: 99, offset: 0, valid: 1, from: 0x4000))
      var second = try XCTUnwrap(TrfsSnapshotStore(writer: ptr, frames: frames))
      d.refuseFlush = true
      XCTAssertFalse(ptr.pointee.branch(from: original))
      d.refuseFlush = false
      d.live = d.stable
      XCTAssertTrue(ptr.pointee.mount())
      XCTAssertEqual(ptr.pointee.snapshot, original)
      XCTAssertFalse(second.store(object: 99, offset: 0, valid: 1, from: 0x4000))
      let fresh = try XCTUnwrap(TrfsSnapshotStore(writer: ptr, frames: frames))
      XCTAssertTrue(fresh.load(object: 99, offset: 0, valid: 1, into: 0x4000))
      XCTAssertEqual(frames.page[0], 3)
    }
  }

  func testCorruptionDoesNotReturnOrOverwriteUserBytes() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let id = try XCTUnwrap(v.create(1, name: b, kind: .file))
    XCTAssertTrue(Data([17]).withUnsafeBytes { v.writePage(id, index: 0, bytes: $0) })
    let root = v.snapshot!
    d.live[4][0] ^= 1  // blob after inode and directory entry
    out.initializeMemory(as: UInt8.self, repeating: 0xcb)
    XCTAssertNil(v.readPage(id, index: 0, in: root, into: out))
    XCTAssertTrue(out.allSatisfy { $0 == 0xcb })
    d.live[3][0] ^= 1
    XCTAssertEqual(v.lookup(1, name: b, in: root), .damaged)
    XCTAssertNil(v.create(1, name: b, kind: .file))
    XCTAssertEqual(v.snapshot, root)
  }

  func testFlushFailureFencesWriterAndReadErrorsDoNotAutoformat() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    d.refuseFlush = true
    XCTAssertNil(v.create(1, name: b, kind: .file))
    XCTAssertNil(v.snapshot)
    XCTAssertNil(v.create(1, name: a, kind: .file))
    d.refuseFlush = false
    d.live = d.stable
    d.unreadable = 0
    XCTAssertFalse(v.mount())
    XCTAssertFalse(v.formatBlank())
    d.unreadable = nil
    XCTAssertFalse(v.formatBlank())
    XCTAssertTrue(v.mount())
    XCTAssertEqual(v.lookup(1, name: b, in: v.snapshot!), .absent)
  }

  func testNoSpaceAndInvalidNamesCannotPublish() throws {
    let d = Disk(Array(repeating: zero, count: 5))
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    for name: [UInt8] in [[], [46], [46, 46], [47], [0], Array(repeating: 97, count: 256)] {
      XCTAssertNil(v.create(1, name: name, kind: .file))
    }
    let id = try XCTUnwrap(v.create(1, name: a, kind: .file))
    let before = v.snapshot
    XCTAssertNil(v.create(id, name: b, kind: .file))
    XCTAssertFalse(Data([33]).withUnsafeBytes { v.writePage(id, index: .max, bytes: $0) })
    XCTAssertFalse(Data([33]).withUnsafeBytes { v.writePage(id, index: 0, bytes: $0) })
    XCTAssertEqual(v.snapshot, before)
  }
}
