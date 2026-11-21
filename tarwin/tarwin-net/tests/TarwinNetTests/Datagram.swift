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
