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

  func testAtomicReplaceAndExchangeOfFileAndLinkAcrossDirectoryCrashCuts() throws {
    for mode: TrfsRenameMode in [.replace, .exchange] {
      let disk = Disk()
      var writer = TrfsVolume(media: disk, scratch: scratch)!
      XCTAssertTrue(writer.formatBlank())
      let dir = try XCTUnwrap(writer.create(1, name: b, kind: .directory))
      let file = try XCTUnwrap(writer.create(1, name: a, kind: .file))
      let link = try XCTUnwrap(writer.createSymlink(dir, name: b, target: a))
      let old = try XCTUnwrap(writer.snapshot)
      XCTAssertFalse(writer.moveFile(1, name: a, to: dir, as: b))
      XCTAssertFalse(writer.moveFile(1, name: a, to: dir, as: a, mode: .exchange))
      XCTAssertFalse(writer.moveFile(1, name: a, to: 1, as: b, mode: mode))
      XCTAssertTrue(writer.moveFile(1, name: a, to: 1, as: a, mode: mode))
      XCTAssertEqual(writer.snapshot, old)
      disk.trace = true
      XCTAssertTrue(writer.moveFile(1, name: a, to: dir, as: b, mode: mode))
      let new = try XCTUnwrap(writer.snapshot)
      XCTAssertNotEqual(old, new)
      var sawOld = false, sawNew = false
      for cut in disk.cuts {
        var recovered = TrfsVolume(media: Disk(cut), scratch: scratch)!
        XCTAssertTrue(recovered.mount())
        let root = try XCTUnwrap(recovered.snapshot)
        let source = recovered.lookup(1, name: a, in: root)
        let target = recovered.lookup(dir, name: b, in: root)
        if root == old {
          sawOld = true
          XCTAssertEqual(source, .file(file))
          XCTAssertEqual(target, .symlink(link))
        } else {
          sawNew = true
          XCTAssertEqual(root, new)
          XCTAssertEqual(source, mode == .exchange ? .symlink(link) : .absent)
          XCTAssertEqual(target, .file(file))
        }
      }
      XCTAssertTrue(sawOld && sawNew)
      XCTAssertEqual(writer.lookup(dir, name: b, in: old), .symlink(link))
    }
  }

  func testReplacePreservesOpenInodeAndFailsClosedOnCorruptDestination() throws {
    let disk = Disk()
    var v = TrfsVolume(media: disk, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let second = try XCTUnwrap(v.create(1, name: b, kind: .file))
    XCTAssertTrue(Data([211]).withUnsafeBytes { v.writePage(second, index: 0, bytes: $0) })
    let first = try XCTUnwrap(v.create(1, name: a, kind: .file))
    let head = try XCTUnwrap(v.snapshot)
    disk.unreadable = second + 1
    XCTAssertEqual(v.lookup(1, name: a, in: head), .file(first))
    XCTAssertEqual(v.lookup(1, name: b, in: head), .damaged)
    XCTAssertFalse(v.moveFile(1, name: a, to: 1, as: b, mode: .replace))
    XCTAssertEqual(v.snapshot, head)
    disk.unreadable = nil
    XCTAssertTrue(v.moveFile(1, name: a, to: 1, as: b, mode: .replace))
    let changed = try XCTUnwrap(v.snapshot)
    XCTAssertEqual(v.lookup(1, name: b, in: changed), .file(first))
    XCTAssertEqual(v.readPage(second, index: 0, in: changed, into: out), 1)
    XCTAssertEqual(out[0], 211)
    XCTAssertTrue(v.moveFile(1, name: b, to: 1, as: a, mode: .replace))
  }

  func testResizeIsSparseAndDoesNotResurrectRemovedBytesAfterRemount() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let file = try XCTUnwrap(v.create(1, name: a, kind: .file))
    let fill = Data(repeating: 0xa5, count: 4096)
    for i: UInt64 in [0, 2] {
      XCTAssertTrue(fill.withUnsafeBytes { v.writePage(file, index: i, bytes: $0) })
    }
    let full = try XCTUnwrap(v.snapshot)
    XCTAssertEqual(v.resize(file, to: 5, limit: .max) { range in
      XCTAssertEqual(range, 5..<12288); return false
    }, .busy)
    XCTAssertEqual(v.resize(file, to: 4097, limit: 4096) { _ in XCTFail(); return true }, .outOfRange)
    XCTAssertEqual(v.snapshot, full)
    XCTAssertEqual(v.resize(file, to: 5, limit: .max) { _ in true }, .ok)
    XCTAssertEqual(v.resize(file, to: .max, limit: .max) { _ in XCTFail(); return false }, .ok)
    var cold = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(cold.mount())
    let root = try XCTUnwrap(cold.snapshot)
    XCTAssertEqual(cold.readPage(file, index: 0, in: root, into: out), 4096)
    XCTAssertTrue(out.prefix(5).allSatisfy { $0 == 0xa5 })
    XCTAssertTrue(out.dropFirst(5).allSatisfy { $0 == 0 })
    for i: UInt64 in [1, 2, .max / 4096] {
      XCTAssertEqual(cold.readPage(file, index: i, in: root, into: out), i == .max / 4096 ? 4095 : 4096)
      XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }
    XCTAssertEqual(cold.readPage(file, index: 2, in: full, into: out), 4096)
    XCTAssertEqual(Data(out), fill)
    XCTAssertTrue(fill.withUnsafeBytes { cold.writePage(file, index: 2, bytes: $0) })
    XCTAssertEqual(cold.readPage(file, index: 2, in: cold.snapshot!, into: out), 4096)
    XCTAssertEqual(Data(out), fill)
    XCTAssertEqual(cold.resize(file, to: 0, limit: .max) { _ in true }, .ok)
    XCTAssertEqual(cold.resize(file, to: 12288, limit: .max) { _ in XCTFail(); return false }, .ok)
    XCTAssertEqual(cold.readPage(file, index: 2, in: cold.snapshot!, into: out), 4096)
    XCTAssertTrue(out.allSatisfy { $0 == 0 })
  }

  func testPartialTruncateCrashNeverExposesMixedLengthAndData() throws {
    let d = Disk()
    var v = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(v.formatBlank())
    let id = try XCTUnwrap(v.create(1, name: a, kind: .file))
    XCTAssertTrue(Data(repeating: 29, count: 4096).withUnsafeBytes {
      v.writePage(id, index: 0, bytes: $0)
    })
    let old = try XCTUnwrap(v.snapshot)
    d.trace = true
    XCTAssertEqual(v.resize(id, to: 10, limit: 4096) { _ in true }, .ok)
    let new = try XCTUnwrap(v.snapshot)
    var before = false, after = false
    for cut in d.cuts {
      var cold = TrfsVolume(media: Disk(cut), scratch: scratch)!
      XCTAssertTrue(cold.mount())
      let head = try XCTUnwrap(cold.snapshot)
      let valid = try XCTUnwrap(cold.readPage(id, index: 0, in: head, into: out))
      if head == old {
        before = true; XCTAssertEqual(valid, 4096)
      } else {
        after = true; XCTAssertEqual(head, new); XCTAssertEqual(valid, 10)
      }
      XCTAssertTrue(out.prefix(valid).allSatisfy { $0 == 29 })
      XCTAssertTrue(out.dropFirst(valid).allSatisfy { $0 == 0 })
    }
    XCTAssertTrue(before && after)
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

  func testBootSetRootIsExactlyOneDigestAndHasNoUnpinnedFallback() throws {
    let d = Disk()
    var writer = TrfsVolume(media: d, scratch: scratch)!
    XCTAssertTrue(writer.formatBlank())
    _ = try XCTUnwrap(writer.create(1, name: b, kind: .file))
    let snapshot = try XCTUnwrap(writer.snapshot)
    var pin = Data(repeating: 0, count: 32)
    XCTAssertTrue(pin.withUnsafeMutableBytes { snapshot.digest.encode(into: $0) })
    var wrong = pin
    wrong[31] ^= 1
    for bad in [Data(), pin.dropLast(), pin + Data([0]), Data(repeating: 0, count: 32), wrong] {
      var boot = TrfsVolume(media: d, scratch: scratch)!
      XCTAssertFalse(bad.withUnsafeBytes {
        boot.mountSystem(bootSetRoot: $0) { _ in XCTFail("unverified measurement"); return true }
      })
      XCTAssertNil(boot.snapshot)
      XCTAssertFalse(boot.mount())
      XCTAssertFalse(pin.withUnsafeBytes {
        boot.mountSystem(bootSetRoot: $0) { _ in XCTFail("second measurement"); return true }
      })
    }
    var clean = TrfsVolume(media: d, scratch: scratch)!
    var events = [TrfsDigest]()
    XCTAssertTrue(pin.withUnsafeBytes {
      clean.mountSystem(bootSetRoot: $0) { events.append($0); return true }
    })
    XCTAssertEqual(events, [snapshot.digest])
    XCTAssertEqual(clean.snapshot, snapshot)
    XCTAssertNil(clean.create(1, name: a, kind: .file))
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
