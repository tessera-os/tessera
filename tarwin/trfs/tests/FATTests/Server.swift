import TRFS
import TarwinDevice
import TarwinFAT
import TarwinFsWire
import TarwinIPC
import XCTest

private struct Shares: FatShares {
  var request: UInt64 = 1, input: [UInt8] = [], capacity: UInt32 = 0, output: [UInt8] = [],
    writes = 0
  func load(request: UInt64, share: UInt64, length: UInt32) -> [UInt8]? {
    self.request == request && share == 1 && length == input.count ? input : nil
  }
  mutating func store(request: UInt64, share: UInt64, capacity: UInt32, bytes: [UInt8]) -> Bool {
    guard request == self.request, share == 2, self.capacity == capacity, bytes.count <= capacity
    else { return false }
    output = bytes
    writes += 1
    return true
  }
}
func mounted(
  _ v: FatVolume<Media>, _ visit: (inout FsRingSession, inout FatServer<Media>) -> Void
) {
  let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
  defer { raw.deallocate() }
  let m = IoRingMapping(initializing: raw, count: 64, stride: 64)!
  var kernel = FsRingSession(
    volume: 9, epoch: 17, limit: 80, requests: m.endpoint(completion: false, producer: true)!,
    replies: m.endpoint(completion: true, producer: false)!)!
  var server = FatServer(
    volume: v, epoch: 17, requests: m.endpoint(completion: false, producer: false)!,
    replies: m.endpoint(completion: true, producer: true)!)!
  visit(&kernel, &server)
}
// Also used with a volume produced by independent mtools.
func throughServer(_ v: FatVolume<Media>, folders: [String], file: String, expected: [UInt8]) {
  mounted(v) { kernel, server in
    var shares = Shares()
    var node = v.root
    func call(
      _ op: TRFS.FsOp, _ offset: UInt64 = 0, _ input: [UInt8] = [], _ capacity: UInt32 = 0,
      _ status: FsStatus = .ok
    ) -> [UInt8] {
      shares.capacity = capacity
      shares.input = input
      shares.output = []
      let pending = kernel.submit(
        op, node: VolumeNode(volume: 9, node: node), other: VolumeNode(volume: 0, node: 0),
        offset: offset, input: input.isEmpty ? 0 : 1, inputBytes: UInt32(input.count),
        output: capacity > 0 ? 2 : 0, outputBytes: capacity,
        resolveShare: { id in
          FsShare(
            volume: 9, id: id, backing: 10, offset: id * 100,
            length: id == 1 ? UInt32(input.count) : capacity, writable: id == 2)
        })
      guard case .ring(.transferred) = pending else {
        XCTFail("Request rejected")
        return []
      }
      XCTAssertEqual(server.step(shares: &shares, signalSpace: {}, signalReply: {}), .replied)
      XCTAssertEqual(
        kernel.poll(signalSpace: {}, revoke: { _ in false }, deliver: { _, _ in XCTFail() }),
        .retiring)
      XCTAssertEqual(
        kernel.poll(
          signalSpace: {}, revoke: { _ in true },
          deliver: { _, done in
            XCTAssertEqual(done.status, status)
            XCTAssertEqual(done.produced, UInt32(shares.output.count))
          }), .completed)
      shares.request += 1
      return shares.output
    }
    func lookup(_ text: String) -> UInt64 {
      let b = call(.lookup, 0, Array(text.utf8), 8)
      return b.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
    for d in folders { node = lookup(d) }
    XCTAssertNotNil(FsEntry(bytes: call(.readDirectory, 0, [], 96)))
    _ = call(.lookup, 0, Array("../x".utf8), 8, .invalid)
    node = lookup(file)
    let attr = FsEntry(bytes: call(.getAttributes, 0, [], 96))
    XCTAssertEqual(attr?.size, UInt64(expected.count))
    XCTAssertEqual(attr?.directory, false)
    XCTAssertEqual(call(.read, 0, [], UInt32(expected.count + 20)), expected)
    _ = call(.write, 0, [1], 0, .readOnly)
    _ = call(.watch, 0, [], 0, .unsupported)
  }
}
final class FatServerTests: XCTestCase {
  func testMountOwnsNodeIdsAndRevokesEveryOutputBeforeDelivery() throws {
    let v = try FatVolume(sample())
    let id = try v.lookup(parent: 1, name: Array("README.TXT".utf8))
    throughServer(
      v, folders: [], file: "readme.txt", expected: try v.bytes(node: id, offset: 0, count: 2048))
  }
  func testFullReplyRingNeverRepeatsShareWrite() throws {
    mounted(try FatVolume(sample())) { kernel, server in
      var shares = Shares()
      var notified = 0
      for _ in 0..<64 {
        guard
          case .ring(.transferred) = kernel.submit(
            .sync, node: VolumeNode(volume: 9, node: 1), other: VolumeNode(volume: 0, node: 0),
            offset: 0, input: 0, inputBytes: 0, output: 0, outputBytes: 0,
            resolveShare: { _ in nil })
        else { return XCTFail() }
        XCTAssertEqual(server.step(shares: &shares, signalSpace: {}, signalReply: {}), .replied)
      }
      shares.request = 65
      shares.capacity = 10
      guard
        case .ring(.transferred) = kernel.submit(
          .read, node: VolumeNode(volume: 9, node: 2), other: VolumeNode(volume: 0, node: 0),
          offset: 512, input: 0, inputBytes: 0, output: 2, outputBytes: 10,
          resolveShare: { _ in
            FsShare(volume: 9, id: 2, backing: 20, offset: 0, length: 10, writable: true)
          })
      else { return XCTFail() }
      for _ in 0..<2 {
        XCTAssertEqual(server.step(shares: &shares, signalSpace: {}, signalReply: {}), .waitReply)
      }
      XCTAssertEqual(
        kernel.poll(
          signalSpace: { notified += 1 }, revoke: { _ in true },
          deliver: { _, d in XCTAssertEqual(d.id, 1) }), .completed)
      XCTAssertEqual(notified, 1)
      XCTAssertEqual(server.step(shares: &shares, signalSpace: {}, signalReply: {}), .replied)
      XCTAssertEqual(shares.writes, 1)
      XCTAssertEqual(shares.output, [1, 2, 3, 4, 5, 6])
      for i: UInt64 in 2...65 {
        XCTAssertEqual(
          kernel.poll(
            signalSpace: {}, revoke: { _ in true },
            deliver: { _, d in
              XCTAssertEqual(d.id, i)
              XCTAssertEqual(d.produced, i == 65 ? 6 : 0)
            }), .completed)
      }
    }
  }
}
