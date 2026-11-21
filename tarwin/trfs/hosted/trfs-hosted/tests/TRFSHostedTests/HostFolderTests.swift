import Darwin
import TRFS
import TarwinDevice
import TarwinFsWire
import TarwinIPC
import TarwinReadOnlyFS
import XCTest

@testable import TarwinHostFolder

struct Shares: ReadOnlyShares {
  var input: [UInt8] = [], output: [UInt8] = []
  func load(request: UInt64, share: UInt64, length: UInt32) -> [UInt8]? {
    share == 1 && length == input.count ? input : nil
  }
  mutating func store(request: UInt64, share: UInt64, capacity: UInt32, bytes: [UInt8]) -> Bool {
    guard share == 2, bytes.count <= capacity else { return false }
    output = bytes
    return true
  }
}

final class HostFolderTests: XCTestCase {
  var dir = "", outside = ""
  var v: HostFolderVolume!
  var shares = Shares()
  var nextID: UInt64 = 1

  override func setUp() {
    dir = tempDir()
    outside = tempDir()
    mkdir(dir + "/docs", 0o755)
    writeFile(dir + "/docs/a.txt", "alpha")
    writeFile(outside + "/secret", "nope")
    symlink(outside + "/secret", dir + "/docs/link")
    symlink(outside, dir + "/escape")
    v = HostFolderVolume(path: dir)
  }
  override func tearDown() {
    removeTree(dir)
    removeTree(outside)
  }

  @discardableResult
  func call(
    _ op: TarwinFsWire.FsOp, _ node: UInt64, other: UInt64 = 0, offset: UInt64 = 0,
    input: [UInt8] = [], out: UInt32 = 0, on vol: HostFolderVolume? = nil
  ) -> (FsStatus, [UInt8]) {
    shares.input = input
    shares.output = []
    let r = FsRecord(
      op: op, id: nextID, node: node, other: other, offset: offset, input: input.isEmpty ? 0 : 1,
      output: out > 0 ? 2 : 0, inputBytes: UInt32(input.count), outputBytes: out)
    nextID += 1
    let (s, n) = (vol ?? v).handle(r, shares: &shares)
    return (s, Array(shares.output.prefix(Int(n))))
  }
  func id(_ b: [UInt8]) -> UInt64 { b.reversed().reduce(0) { $0 << 8 | UInt64($1) } }
  func lookup(_ parent: UInt64, _ name: String) -> UInt64? {
    let (s, b) = call(.lookup, parent, input: Array(name.utf8), out: 8)
    return s == .ok ? id(b) : nil
  }

  func testLookupReadAndList() throws {
    let docs = try XCTUnwrap(lookup(1, "docs"))
    let a = try XCTUnwrap(lookup(docs, "a.txt"))
    XCTAssertEqual(lookup(docs, "a.txt"), a, "stable node numbers")
    XCTAssertEqual(call(.read, a, offset: 1, out: 64).1, Array("lpha".utf8))
    let attr = FsEntry(bytes: call(.getAttributes, a, out: 300).1)
    XCTAssertEqual(attr, FsEntry(id: a, size: 5, directory: false, name: Array("a.txt".utf8)))
    let first = FsEntry(bytes: call(.readDirectory, docs, offset: 0, out: 300).1)
    XCTAssertEqual(first?.name, Array("a.txt".utf8))
    XCTAssertEqual(call(.readDirectory, docs, offset: 1, out: 300).1, [], "symlinks are hidden")
    XCTAssertEqual(call(.lookup, docs, input: Array("missing".utf8), out: 8).0, .notFound)
  }

  func testNeverLeavesGrantedFolder() throws {
    let docs = try XCTUnwrap(lookup(1, "docs"))
    XCTAssertEqual(call(.lookup, docs, input: Array("link".utf8), out: 8).0, .denied)
    XCTAssertEqual(call(.lookup, 1, input: Array("escape".utf8), out: 8).0, .denied)
    XCTAssertEqual(call(.lookup, docs, input: Array("..".utf8), out: 8).0, .invalid)
    XCTAssertEqual(call(.lookup, 1, input: Array("docs/a.txt".utf8), out: 8).0, .invalid)
    XCTAssertEqual(
      call(.create, 1, offset: 1, input: Array("../x".utf8), out: 8).0, .invalid)
    XCTAssertEqual(call(.read, 999, out: 8).0, .notFound, "unknown nodes")
    // A file swapped for a symlink after lookup is refused, not followed.
    let a = try XCTUnwrap(lookup(docs, "a.txt"))
    unlink(dir + "/docs/a.txt")
    symlink(outside + "/secret", dir + "/docs/a.txt")
    XCTAssertEqual(call(.read, a, out: 64).0, .denied)
    XCTAssertEqual(readFile(outside + "/secret"), "nope")
  }

  func testCreateWriteRenameRemove() throws {
    let (s, b) = call(.create, 1, offset: 2, input: Array("new".utf8), out: 8)
    XCTAssertEqual(s, .ok)
    let newDir = id(b)
    let f = id(call(.create, newDir, offset: 1, input: Array("f".utf8), out: 8).1)
    XCTAssertEqual(call(.create, newDir, offset: 1, input: Array("f".utf8), out: 8).0, .exists)
    XCTAssertEqual(call(.write, f, offset: 0, input: Array("hello world".utf8)).0, .ok)
    XCTAssertEqual(call(.setAttributes, f, offset: 5).0, .ok)
    XCTAssertEqual(call(.flush, f).0, .ok)
    XCTAssertEqual(readFile(dir + "/new/f"), "hello")
    let docs = try XCTUnwrap(lookup(1, "docs"))
    XCTAssertEqual(
      call(.rename, newDir, other: docs, input: Array("f".utf8) + [0] + Array("g".utf8)).0, .ok)
    XCTAssertEqual(readFile(dir + "/docs/g"), "hello")
    XCTAssertEqual(call(.read, f, out: 16).1, Array("hello".utf8), "node follows rename")
    XCTAssertEqual(call(.remove, 1, input: Array("docs".utf8)).0, .notEmpty)
    XCTAssertEqual(call(.remove, docs, input: Array("g".utf8)).0, .ok)
    XCTAssertEqual(call(.read, f, out: 16).0, .notFound)
    XCTAssertEqual(call(.remove, 1, input: Array("new".utf8)).0, .ok)
    XCTAssertEqual(call(.sync, 1).0, .ok)
    XCTAssertEqual(call(.statFileSystem, 1, out: 16).1.count, 16)
  }

  func testReadOnlyGrant() throws {
    let ro = try XCTUnwrap(HostFolderVolume(path: dir, readOnly: true))
    let docs = try XCTUnwrap(id(call(.lookup, 1, input: Array("docs".utf8), out: 8, on: ro).1))
    XCTAssertEqual(call(.create, docs, offset: 1, input: Array("x".utf8), out: 8, on: ro).0, .readOnly)
    XCTAssertEqual(call(.remove, docs, input: Array("a.txt".utf8), on: ro).0, .readOnly)
    XCTAssertEqual(readFile(dir + "/docs/a.txt"), "alpha")
  }

  func testThroughKernelRing() throws {
    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
    defer { raw.deallocate() }
    let m = IoRingMapping(initializing: raw, count: 64, stride: 64)!
    var kernel = FsRingSession(
      volume: 9, epoch: 17, limit: 80, requests: m.endpoint(completion: false, producer: true)!,
      replies: m.endpoint(completion: true, producer: false)!)!
    var server = HostFolderServer(
      volume: v, epoch: 17, requests: m.endpoint(completion: false, producer: false)!,
      replies: m.endpoint(completion: true, producer: true)!)!
    shares.input = Array("docs".utf8)
    let pending = kernel.submit(
      .lookup, node: VolumeNode(volume: 9, node: 1), other: VolumeNode(volume: 0, node: 0),
      offset: 0, input: 1, inputBytes: 4, output: 2, outputBytes: 8,
      resolveShare: { id in
        FsShare(volume: 9, id: id, backing: 10, offset: id * 100, length: id == 1 ? 4 : 8,
          writable: id == 2)
      })
    guard case .ring(.transferred) = pending else { return XCTFail("rejected") }
    XCTAssertEqual(server.step(shares: &shares, signalSpace: {}, signalReply: {}), .replied)
    XCTAssertEqual(
      kernel.poll(signalSpace: {}, revoke: { _ in false }, deliver: { _, _ in XCTFail() }),
      .retiring)
    var status: FsStatus?
    XCTAssertEqual(
      kernel.poll(signalSpace: {}, revoke: { _ in true }, deliver: { _, d in status = d.status }),
      .completed)
    XCTAssertEqual(status, .ok)
    XCTAssertEqual(id(shares.output), lookup(1, "docs"))
  }

  /// The fd crosses a socket with SCM_RIGHTS, as it does over XPC.
  func testServesPassedDirectoryFD() throws {
    var sv: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
    defer { close(sv[0]); close(sv[1]) }
    let sent = open(dir, O_RDONLY | O_DIRECTORY)
    XCTAssertTrue(sendFD(sent, on: sv[0]))
    close(sent)
    let got = try XCTUnwrap(receiveFD(on: sv[1]))
    let vol = try XCTUnwrap(HostFolderVolume(directoryFD: got, readOnly: true))
    let docs = try XCTUnwrap(lookupOn(vol, HostFolderVolume.root, "docs"))
    XCTAssertNotNil(lookupOn(vol, docs, "a.txt"))
    XCTAssertNil(lookupOn(vol, HostFolderVolume.root, "escape"))
    XCTAssertEqual(call(.create, docs, offset: 1, input: Array("n".utf8), out: 8, on: vol).0, .readOnly)
    let file = open(dir + "/docs/a.txt", O_RDONLY)
    XCTAssertNil(HostFolderVolume(directoryFD: file))
    XCTAssertEqual(fcntl(file, F_GETFD), -1, "refused fd is closed")
  }
  func lookupOn(_ vol: HostFolderVolume, _ parent: UInt64, _ name: String) -> UInt64? {
    let (s, b) = call(.lookup, parent, input: Array(name.utf8), out: 8, on: vol)
    return s == .ok ? id(b) : nil
  }
  func sendFD(_ fd: Int32, on sock: Int32) -> Bool {
    var byte: UInt8 = 0
    let space = Int(CMSG_SPACE_INT())
    var control = [UInt8](repeating: 0, count: space)
    return withUnsafeMutablePointer(to: &byte) { bp in
      var iov = iovec(iov_base: bp, iov_len: 1)
      return withUnsafeMutablePointer(to: &iov) { iovp in
        control.withUnsafeMutableBytes { cb in
          var m = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
            msg_control: cb.baseAddress, msg_controllen: socklen_t(space), msg_flags: 0)
          let c = cb.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
          c.pointee = cmsghdr(cmsg_len: socklen_t(MemoryLayout<cmsghdr>.size + 4),
            cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
          (cb.baseAddress! + MemoryLayout<cmsghdr>.size).storeBytes(of: fd, as: Int32.self)
          return sendmsg(sock, &m, 0) == 1
        }
      }
    }
  }
  func receiveFD(on sock: Int32) -> Int32? {
    var byte: UInt8 = 0
    let space = Int(CMSG_SPACE_INT())
    var control = [UInt8](repeating: 0, count: space)
    return withUnsafeMutablePointer(to: &byte) { bp in
      var iov = iovec(iov_base: bp, iov_len: 1)
      return withUnsafeMutablePointer(to: &iov) { iovp in
        control.withUnsafeMutableBytes { cb -> Int32? in
          var m = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
            msg_control: cb.baseAddress, msg_controllen: socklen_t(space), msg_flags: 0)
          guard recvmsg(sock, &m, 0) == 1 else { return nil }
          let c = cb.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
          guard c.pointee.cmsg_type == SCM_RIGHTS else { return nil }
          return (cb.baseAddress! + MemoryLayout<cmsghdr>.size).load(as: Int32.self)
        }
      }
    }
  }
  func CMSG_SPACE_INT() -> Int { (MemoryLayout<cmsghdr>.size + 4 + 7) & ~7 }
}
