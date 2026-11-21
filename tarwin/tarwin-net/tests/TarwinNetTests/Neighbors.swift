import XCTest

@testable import TarwinNet

final class NeighborTests: XCTestCase {
  let a: [UInt8] = [2, 0, 0, 0, 0, 1], b: [UInt8] = [2, 0, 0, 0, 0, 2]
  let ips: [[UInt8]] = [[192, 0, 2, 1], [0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]]
  func pair(_ ip: [UInt8]) -> (NeighborInterface, NeighborInterface) {
    var peer = ip
    peer[peer.count - 1] = 2
    return (NeighborInterface(mac: a, address: ip)!, NeighborInterface(mac: b, address: peer)!)
  }
  func testResolutionIsSolicitedBoundedAndExpires() throws {
    for ip in ips {
      let (left, right) = pair(ip)
      var cache = NeighborTable(
        interface: left, limit: 1, retryNs: 4, reachableNs: 12, attempts: 2)!
      let req = try XCTUnwrap(left.probe(right.address))
      let ans = try XCTUnwrap(right.reply(req))
      XCTAssertFalse(cache.confirm(ans, now: 0))
      XCTAssertEqual(cache.resolve(right.address, now: 1), .send(req))
      XCTAssertEqual(cache.resolve(right.address, now: 2), .waiting)
      var other = right.address
      other[other.count - 1] = 8
      XCTAssertEqual(cache.resolve(other, now: 2), .unavailable)
      XCTAssertFalse(cache.confirm(ans, now: 5))  // timed out
      XCTAssertEqual(cache.resolve(right.address, now: 5), .send(req))
      XCTAssertTrue(cache.confirm(ans, now: 6))
      XCTAssertFalse(cache.confirm(ans, now: 7))
      XCTAssertEqual(cache.resolve(right.address, now: 8), .resolved(b))
      XCTAssertEqual(cache.resolve(right.address, now: 18), .send(req))
      XCTAssertEqual(cache.resolve(right.address, now: 17), .unavailable)
      XCTAssertEqual(cache.resolve(right.address, now: 22), .send(req))
      XCTAssertEqual(cache.resolve(right.address, now: 26), .unavailable)
    }
  }
  func checksum(_ frame: inout [UInt8]) {
    putWord(&frame, 56, 0)
    let n = Int(word(frame, 18))
    let sum = sumBytes(frame, 22, 32, UInt32(n) + 58)
    putWord(&frame, 56, 65535 ^ sumBytes(frame, 54, n, sum))
  }
  func testNDValidatesHopChecksumOptionsAndDuplicateAddressDetection() throws {
    let (left, right) = pair(ips[1])
    let req = try XCTUnwrap(left.probe(right.address))
    let ans = try XCTUnwrap(right.reply(req))
    XCTAssertEqual(Array(req[0..<6]), [0x33, 0x33, 0xff, 0, 0, 2])
    var cache = NeighborTable(interface: left, limit: 4, retryNs: 8, reachableNs: 14)!
    XCTAssertEqual(cache.resolve(right.address, now: 1), .send(req))
    for i in [0, 6, 20, 21, 39, 55, 56, 62, 78, 79, 80] {
      var bad = ans
      bad[i] ^= 1
      XCTAssertFalse(cache.confirm(bad, now: 2), "changed byte \(i)")
    }
    var bad = ans
    bad[79] = 0
    checksum(&bad)
    XCTAssertFalse(cache.confirm(bad, now: 2))
    bad = ans
    bad[58] &= 0xbf
    checksum(&bad)
    XCTAssertFalse(cache.confirm(bad, now: 2))
    bad = ans
    bad[85] ^= 1
    checksum(&bad)
    XCTAssertFalse(cache.confirm(bad, now: 2))
    var dad = req
    dad.replaceSubrange(22..<38, with: Array(repeating: 0, count: 16))
    checksum(&dad)
    XCTAssertNil(right.reply(dad))
    dad.removeLast(8)
    dad[19] = 24
    checksum(&dad)
    let defense = try XCTUnwrap(right.reply(dad))
    XCTAssertEqual(Array(defense[0..<6]), [0x33, 0x33, 0, 0, 0, 1])
    XCTAssertEqual(defense[58] & 0x40, 0)
    XCTAssertFalse(cache.confirm(defense, now: 2))
    XCTAssertTrue(cache.confirm(ans, now: 2))
  }
  func testArpRejectsWrongTargetSenderAndHeader() throws {
    let (left, right) = pair(ips[0])
    let req = try XCTUnwrap(left.probe(right.address))
    XCTAssertEqual(Array(req.prefix(6)), Array(repeating: 255, count: 6))
    var cache = NeighborTable(interface: left, limit: 1, retryNs: 8, reachableNs: 10)!
    let ans = try XCTUnwrap(right.reply(req))
    _ = cache.resolve(right.address, now: 1)
    for i in [0, 6, 12, 14, 16, 18, 19, 20, 21, 22, 28, 32, 38] {
      var bad = ans
      bad[i] ^= 1
      XCTAssertFalse(cache.confirm(bad, now: 2))
    }
    for n in 0..<42 { XCTAssertNil(right.reply(Array(req.prefix(n)))) }
    XCTAssertTrue(cache.confirm(ans + Array(repeating: 0, count: 18), now: 2))
  }
}
