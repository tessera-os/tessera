import XCTest

@testable import TarwinNet

final class RouterDiscoveryTests: XCTestCase {
  // Captured from restricted libslirp on the independent q35 check.
  let capture =
    "33330000000152560000000286dd6000000000383afffe800000000000000000000000000002ff020000000000000000000000000001860016fb4000070800000000000000000101525600000002030440c0000151800000384000000000fd000023000000000000000000000000"
  let local: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 15]
  let iid: [UInt8] = [0, 0, 0, 0, 0, 0, 2, 15]
  var link: NeighborInterface { .init(mac: [0x52, 0x54, 0, 0, 0, 1], address: local)! }
  var frame: [UInt8] {
    var b: [UInt8] = []
    var i = capture.startIndex
    while i != capture.endIndex {
      let j = capture.index(i, offsetBy: 2)
      b.append(UInt8(capture[i..<j], radix: 16)!)
      i = j
    }
    return b
  }
  func seal(_ b: inout [UInt8]) {
    putWord(&b, 56, 0)
    putWord(&b, 56, 65535 ^ ndSum(b, Int(word(b, 18))))
  }
  func feed(_ b: [UInt8], _ s: inout RouterDiscovery, _ now: UInt64) -> Bool {
    s.receiveAdvertisement(b, at: now) { _, _ in true }
  }
  func testCapturedPrefixAndIndependentLifetimes() {
    var state = RouterDiscovery(link: link, identifier: iid, dadTransmits: 2)!
    XCTAssertTrue(feed(frame, &state, 10))
    XCTAssertEqual(state.defaultRouters(at: 10), [Array(frame[22..<38])])
    XCTAssertFalse(state.probeTentative(at: 10) { _ in false })
    XCTAssertEqual(state.addresses(at: 100)[0].1, .tentative)
    for time: UInt64 in [100, 101] {
      XCTAssertTrue(
        state.probeTentative(at: time) { b in
          b.count == 78 && b[54] == 135 && b[22..<38].allSatisfy { $0 == 0 }
            && ndSum(b, 24) == 65535
        })
      XCTAssertEqual(state.addresses(at: time)[0].1, .tentative)
    }
    XCTAssertEqual(state.addresses(at: 102)[0].1, .preferred)
    var short = frame
    for i in [60, 61, 82, 83, 84, 85, 86, 87, 88, 89] { short[i] = 0 }
    seal(&short)
    XCTAssertTrue(feed(short, &state, 103))
    XCTAssertTrue(state.defaultRouters(at: 103).isEmpty)
    XCTAssertEqual(state.addresses(at: 103)[0].1, .deprecated)
    XCTAssertTrue(feed(short, &state, 150))
    XCTAssertEqual(state.addresses(at: 7302)[0].1, .deprecated)
    XCTAssertTrue(state.addresses(at: 7303).isEmpty)
    XCTAssertFalse(feed(frame, &state, 7302))
  }
  func testInvalidAdvertisementsCannotInstallOrRefreshState() {
    var state = RouterDiscovery(link: link, identifier: iid)!
    for n in 0..<frame.count { XCTAssertFalse(feed(Array(frame.prefix(n)), &state, 0)) }
    for (at, value) in [
      (21, 254), (20, 44), (55, 1), (22, 0x20), (38, 0x40), (71, 0), (79, 2), (72, 0),
    ] {
      var bad = frame
      bad[at] = UInt8(value)
      seal(&bad)
      XCTAssertFalse(feed(bad, &state, 0), "invalid field at " + String(at))
    }
    var bad = frame
    bad[56] ^= 1
    XCTAssertFalse(feed(bad, &state, 0))
    XCTAssertFalse(state.receiveAdvertisement(frame, at: 0) { _, _ in false })
    XCTAssertTrue(state.addresses(at: 0).isEmpty)
    XCTAssertTrue(state.defaultRouters(at: 0).isEmpty)
    for (at, value) in [(80, 63), (81, 128), (86, 127), (94, 255)] {
      bad = frame
      bad[at] = UInt8(value)
      seal(&bad)
      XCTAssertTrue(feed(bad, &state, 0))
      XCTAssertTrue(state.addresses(at: 0).isEmpty)
    }
  }
  func testDuplicateDisablesTentativeAddressUntilExpiry() {
    for defense in [true, false] {
      var state = RouterDiscovery(link: link, identifier: iid)!
      XCTAssertTrue(feed(frame, &state, 0))
      let address = state.addresses(at: 0)[0].0
      var wire: [UInt8] = []
      XCTAssertTrue(
        state.probeTentative(at: 1) {
          wire = $0
          return true
        })
      let peer = NeighborInterface(mac: [2, 0, 0, 0, 0, 9], address: address)!
      if defense { wire = peer.reply(wire)! } else { wire.replaceSubrange(6..<12, with: peer.mac) }
      XCTAssertTrue(state.observeConflict(wire, at: 1))
      XCTAssertTrue(feed(frame, &state, 2))
      XCTAssertEqual(state.addresses(at: 2)[0].1, .duplicate)
      XCTAssertFalse(state.probeTentative(at: 50) { _ in true })
      XCTAssertTrue(state.addresses(at: 86402).isEmpty)
    }
  }
}
