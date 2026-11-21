import XCTest

@testable import TarwinNet

final class UdpOutputTests: XCTestCase {
  func testNetworkOrderAndChecksumsMatchIndependentIpFixture() {
    let route = UdpRoute(
      family: .v4, source: [192, 0, 2, 1], destination: [198, 51, 100, 2],
      sourcePort: 1234, destinationPort: 5678, hops: 64, mtu: 31)
    switch udpOutput(route, [97, 98, 99]) {
    case .packet(let bytes):
      let expected: [UInt8] = [
        0x45, 0, 0, 31, 0, 0, 0x40, 0, 64, 17, 0x4e, 0x97,
        192, 0, 2, 1, 198, 51, 100, 2, 4, 210, 0x16, 46, 0, 11, 0x34, 0x3e, 97, 98, 99,
      ]
      XCTAssertTrue(expected == bytes)
    default: XCTAssertTrue(false)
    }
    XCTAssertTrue(udpOutput(route, [97, 98, 99, 100]) == OutputResult.tooLarge)
  }

  func testRegisteredReceiveRemainsPendingOnPolicyDenial() {
    let addr: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    let route = UdpRoute(
      family: .v6, source: addr, destination: addr, sourcePort: 42,
      destinationPort: 9, hops: 64, mtu: 1280)
    var endpoint = UdpEndpoint(process: 101, family: .v6, port: 9, limit: 2)
    let receive = RegisteredReceive(process: 101, key: 3, memory: 4, offset: 1, length: 2)
    let pin: (UInt64, UInt64, UInt64, UInt32) -> Bool = { p, m, o, n in return p == 101 && m == 4 }
    XCTAssertTrue(endpoint.post(receive, pin))
    XCTAssertTrue(!endpoint.post(receive, pin))
    switch udpOutput(route, [0xab, 0xcd, 0xef]) {
    case .packet(let bytes):
      var allowed = false
      var unpinned: UInt64 = 0
      let policy: (UInt64, UInt64, [UInt8]) -> Bool = { p, iface, ip in
        return allowed && p == 101 && iface == 3
      }
      let copyOut: (RegisteredReceive, [UInt8], Int, Int) -> Bool = { r, ip, at, n in
        return ip[at] == 0xab && ip[at + 1] == 0xcd && n == 2
      }
      let done: (RegisteredReceive, UInt32, Bool) -> Void = { r, n, ok in
        if ok && n == 2 { unpinned = r.memory }
      }
      endpoint.peerPort = 99
      XCTAssertTrue(endpoint.deliver(bytes, 3, policy, copyOut, done) == ReceiveResult.noMatch)
      endpoint.peerPort = 42
      endpoint.peer = addr
      endpoint.local = addr
      XCTAssertTrue(endpoint.deliver(bytes, 3, policy, copyOut, done) == ReceiveResult.policyDenied)
      XCTAssertTrue(endpoint.count == 1 && unpinned == 0)
      allowed = true
      XCTAssertTrue(endpoint.deliver(bytes, 3, policy, copyOut, done) == ReceiveResult.delivered(2))
      XCTAssertTrue(endpoint.count == 0 && unpinned == 4)
      XCTAssertTrue(endpoint.deliver(bytes, 3, policy, copyOut, done) == ReceiveResult.wouldBlock)
    default: XCTAssertTrue(false)
    }
    XCTAssertTrue(endpoint.post(receive, pin))
    var cancelled: UInt64 = 0
    endpoint.shutdown({ r in cancelled = r.key })
    XCTAssertTrue(cancelled == 3 && !endpoint.post(receive, pin))
  }
}
