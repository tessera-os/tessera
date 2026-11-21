import XCTest

@testable import TarwinNet

final class DatagramTests: XCTestCase {
  func testIpv4OddDatagramIncludesPseudoHeaderAndExcludesPadding() {
    var packet: [UInt8] = [
      0x45, 0, 0, 31, 0, 0, 0x40, 0, 64, 17, 0x4e, 0x97, 192, 0, 2, 1, 198, 51, 100, 2,
      4, 210, 0x16, 46, 0, 11, 0x34, 0x3e, 97, 98, 99, 0, 0,
    ]
    switch decodeUdp(packet) {
    case .accepted(let d):
      XCTAssertTrue(d.destinationPort == 5678 && d.payload == 28 && d.length == 3)
    default: XCTAssertTrue(false)
    }
    packet[30] = 0
    XCTAssertTrue(decodeUdp(packet) == UdpDecode.invalid)
    packet[26] = 0
    packet[27] = 0
    switch decodeUdp(packet) {
    case .accepted(_): break
    default: XCTAssertTrue(false)
    }
    packet[10] = 0
    XCTAssertTrue(decodeUdp(packet) == UdpDecode.invalid)
  }

  func testIpv6RequiresChecksum() {
    var packet: [UInt8] = [
      96, 0, 0, 0, 0, 8, 17, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 2, 0, 8, 0, 0,
    ]
    XCTAssertTrue(decodeUdp(packet) == UdpDecode.invalid)
    packet[46] = 0xff
    packet[47] = 0xd9
    switch decodeUdp(packet) {
    case .accepted(let d): XCTAssertTrue(d.family == IpFamily.v6 && d.length == 0)
    default: XCTAssertTrue(false)
    }
    packet[6] = 44
    XCTAssertTrue(decodeUdp(packet) == UdpDecode.fragment)
  }

  // Darwin sendmsg(::1) with IPV6_HOPOPTS and IPV6_DSTOPTS. Captured on lo0;
  // the receiving kernel delivered "Tarwin-UDP6" and tcpdump verified the checksum.
  private var darwinUDP: [UInt8] {
    [
      0x60, 6, 2, 0, 0, 35, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 60, 0, 1, 4, 0, 0, 0, 0, 17, 0, 0, 0, 1, 2, 0,
      0,
      0xfc, 0xe5, 0xd0, 0xfd, 0, 19, 0x59, 0xf6, 84, 97, 114, 119, 105, 110, 45, 85, 68, 80, 54,
    ]
  }

  func testDarwinPaddingHeadersPreserveUpperLayerChecksumAndOffsets() {
    for first: UInt8 in [0, 60, 17] {
      var ip = darwinUDP
      if first != 0 {
        let skip = first == 60 ? 8 : 16
        ip.removeSubrange(40..<40 + skip)
        ip[5] -= UInt8(skip)
        ip[6] = first
      }
      ip += [0xab, 0xcd]  // Link padding must not reach the endpoint.
      guard case .accepted(let d) = decodeUdp(ip) else { return XCTFail("header \(first)") }
      XCTAssertEqual(d.family, .v6)
      XCTAssertEqual(d.sourcePort, 64741)
      XCTAssertEqual(d.destinationPort, 53501)
      XCTAssertEqual(ip[d.payload..<d.payload + d.length], ArraySlice("Tarwin-UDP6".utf8))
    }
  }

  func testOnlyOrderedPaddingWithinDeclaredIPv6PayloadIsAccepted() {
    func check(_ at: Int, _ value: UInt8, _ expected: UdpDecode) {
      var ip = darwinUDP
      ip[at] = value
      XCTAssertEqual(decodeUdp(ip), expected)
    }
    check(5, 1, .invalid)
    check(41, 255, .invalid)
    check(43, 5, .invalid)
    check(44, 1, .invalid)
    check(42, 5, .unsupported)
    check(40, 0, .unsupported)
    check(6, 60, .unsupported)
    check(48, 43, .unsupported)
    check(48, 44, .fragment)
    check(48, 50, .unsupported)
    check(64, 0, .invalid)
    var ip = darwinUDP
    ip[52...55] = [0, 0, 0, 1]  // PadN missing its length at end of header.
    XCTAssertEqual(decodeUdp(ip), .invalid)
    ip = darwinUDP
    ip[62...63] = [0, 0]
    XCTAssertEqual(decodeUdp(ip), .invalid)
  }

  func testBackgroundYieldsOnlyWhenCongestedAndPacedTrafficWaits() {
    let heads = [
      FlowHead(notBefore: 0, background: true, finish: 1, ordinal: 0),
      FlowHead(notBefore: 0, background: false, finish: 9, ordinal: 1),
      FlowHead(notBefore: 7, background: false, finish: 3, ordinal: 2),
    ]
    XCTAssertTrue(nextFlow(heads, 1, false) == 0)
    XCTAssertTrue(nextFlow(heads, 1, true) == 1)
    XCTAssertTrue(nextFlow(heads, 7, true) == 2)
    XCTAssertTrue(flowFinish(30, 90, 64) == 154)
  }
}
