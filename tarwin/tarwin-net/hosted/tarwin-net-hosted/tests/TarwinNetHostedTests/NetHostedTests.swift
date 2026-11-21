import Darwin
import XCTest

@testable import TarwinNetHosted

final class NetHostedTests: XCTestCase {
  let v4 = NetAddress.loopback(.v4)

  func net(_ rules: [NetRule] = [], client: Bool = true, server: Bool = false) -> HostedNetwork {
    let p = NetPolicy(rules: rules)
    p.setEntitlements(NetEntitlements(client: client, server: server), for: "app")
    return HostedNetwork(policy: p)
  }
  func wait(_ fd: Int32, write: Bool = false) {
    var p = pollfd(fd: fd, events: Int16(write ? POLLOUT : POLLIN), revents: 0)
    XCTAssertEqual(poll(&p, 1, 2000), 1)
  }

  func testAddressesAndPrefixes() {
    XCTAssertEqual(NetAddress("10.1.2.3", port: 80)?.description, "10.1.2.3:80")
    XCTAssertEqual(NetAddress("::1", port: 5)?.description, "[::1]:5")
    XCTAssertNil(NetAddress("example.com", port: 1), "no name lookups")
    let mapped = NetAddress("::ffff:10.0.0.1", port: 0)!
    XCTAssertTrue(NetPrefix("10.0.0.0/8")!.contains(mapped))
    XCTAssertFalse(NetPrefix("10.0.0.0/8")!.contains(NetAddress("11.0.0.1", port: 0)!))
    XCTAssertTrue(NetPrefix("fe80::/10")!.contains(NetAddress("fe80::1", port: 0)!))
    XCTAssertNil(NetPrefix("10.0.0.0/33"))
    XCTAssertTrue(mapped.unmapped.family == .v4)
  }

  func testPolicyOrderAndEntitlements() {
    let p = NetPolicy(rules: [
      NetRule(.deny, app: "app", prefix: NetPrefix("192.168.0.0/16")),
      NetRule(.allow, app: "other", proto: .udp, direction: .outbound, ports: 53...53),
    ])
    p.setEntitlements(NetEntitlements(client: true), for: "app")
    p.setEntitlements(NetEntitlements(), for: "other")
    func f(_ app: String, _ d: NetDirection, _ a: String, _ port: UInt16 = 443,
      _ pr: NetProtocol = .tcp) -> NetVerdict
    { p.check(NetFlow(app: app, proto: pr, direction: d, address: NetAddress(a, port: port)!)) }
    XCTAssertEqual(f("app", .outbound, "1.1.1.1"), .allow)
    XCTAssertEqual(f("app", .outbound, "192.168.1.1"), .deny("rule"))
    XCTAssertEqual(f("app", .listen, "0.0.0.0", 8080), .deny("no server entitlement"))
    XCTAssertEqual(f("app", .listen, "127.0.0.1", 8080), .allow)
    XCTAssertEqual(f("app", .outbound, "224.0.0.251", 5353, .udp), .deny("multicast"))
    XCTAssertEqual(f("other", .outbound, "1.1.1.1"), .deny("no client entitlement"))
    XCTAssertEqual(f("other", .outbound, "8.8.8.8", 53, .udp), .allow)
    XCTAssertEqual(f("ghost", .outbound, "1.1.1.1"), .deny("unknown app"))
  }

  /// The hosted client fixture grant: app-bound allow 43871, deny 43872, terminal deny-all.
  func testClientFixtureGrant() throws {
    let p = NetPolicy(rules: [
      NetRule(.allow, app: "fixture", proto: .tcp, direction: .outbound, ports: 43871...43871),
      NetRule(.deny, app: "fixture", ports: 43872...43872),
      NetRule(.deny),
    ])
    p.setEntitlements(NetEntitlements(client: true), for: "fixture")
    let n = HostedNetwork(policy: p)
    let l = try HostedNetwork(policy: {
      let q = NetPolicy(); q.setEntitlements(NetEntitlements(client: true), for: "x"); return q
    }()).listen(app: "x", on: .loopback(.v4, port: 43871))
    defer { l.close() }
    let c = try n.connect(app: "fixture", to: .loopback(.v4, port: 43871))
    wait(c.fd, write: true)
    XCTAssertEqual(c.connectResult(), .some(nil))
    c.close()
    let before = openFDs()
    for port: UInt16 in [43872, 80] {
      XCTAssertThrowsError(try n.connect(app: "fixture", to: .loopback(.v4, port: port))) {
        XCTAssertEqual($0 as? NetError, .denied("rule"))
      }
    }
    XCTAssertThrowsError(try n.connect(app: "other", to: .loopback(.v4, port: 43871)))
    XCTAssertEqual(openFDs(), before, "no socket before a denial")
  }

  func testDeniedFlowNeverOpensASocket() throws {
    let n = net(client: false)
    let before = openFDs()
    XCTAssertThrowsError(try n.connect(app: "app", to: NetAddress("1.1.1.1", port: 443)!)) {
      XCTAssertEqual($0 as? NetError, .denied("no client entitlement"))
    }
    XCTAssertEqual(openFDs(), before)
    XCTAssertEqual(n.deniedCount, 1)
    XCTAssertEqual(n.openCount("app"), 0)
  }

  func testTcpLoopbackEcho() throws {
    let n = net()
    let l = try n.listen(app: "app", on: v4)
    let port = try XCTUnwrap(l.local?.port)
    let c = try n.connect(app: "app", to: .loopback(.v4, port: port))
    wait(l.fd)
    let s = try l.accept()
    XCTAssertTrue(s.remote?.isLoopback == true)
    wait(c.fd, write: true)
    XCTAssertEqual(c.connectResult(), .some(nil))
    let msg = Array("ping".utf8)
    XCTAssertEqual(msg.withUnsafeBytes { c.send($0) }, .bytes(4))
    wait(s.fd)
    var buf = [UInt8](repeating: 0, count: 16)
    XCTAssertEqual(buf.withUnsafeMutableBytes { s.receive(into: $0) }, .bytes(4))
    XCTAssertEqual(Array(buf.prefix(4)), msg)
    XCTAssertEqual(buf.withUnsafeMutableBytes { c.receive(into: $0) }, .wouldBlock)
    XCTAssertEqual(n.openCount("app"), 3)
    s.close()
    wait(c.fd)
    XCTAssertEqual(buf.withUnsafeMutableBytes { c.receive(into: $0) }, .closed)
    XCTAssertEqual(n.openCount("app"), 2)
  }

  func testListenerDropsFilteredPeers() throws {
    XCTAssertThrowsError(try net().listen(app: "app", on: .any(.v4))) {
      XCTAssertEqual($0 as? NetError, .denied("no server entitlement"))
    }
    let n = net([NetRule(.deny, direction: .inbound, prefix: NetPrefix("127.0.0.1/32"))], server: true)
    let l = try n.listen(app: "app", on: .any(.v4))
    let port = try XCTUnwrap(l.local?.port)
    let other = net()
    let c = try other.connect(app: "app", to: .loopback(.v4, port: port))
    wait(l.fd)
    XCTAssertThrowsError(try l.accept()) { XCTAssertEqual($0 as? NetError, .wouldBlock) }
    XCTAssertEqual(n.deniedCount, 1)
    wait(c.fd)
    var buf = [UInt8](repeating: 0, count: 4)
    XCTAssertEqual(buf.withUnsafeMutableBytes { c.receive(into: $0) }, .closed)
  }

  func testUdpFilteringAndReplies() throws {
    let n = net()
    let a = try n.datagram(app: "app", on: v4)
    let peer = HostedNetwork(policy: NetPolicy())
    peer.policy.setEntitlements(NetEntitlements(client: true), for: "peer")
    let b = try peer.datagram(app: "peer", on: v4)
    let bAddr = try XCTUnwrap(b.local)
    let aAddr = try XCTUnwrap(a.local)
    // b has not sent to a, and loopback inbound is allowed for client apps.
    XCTAssertEqual(try Array("hi".utf8).withUnsafeBytes { try a.sendDatagram($0, to: bAddr) }, .bytes(2))
    wait(b.fd)
    var buf = [UInt8](repeating: 0, count: 8)
    let got = try buf.withUnsafeMutableBytes { try b.receiveDatagram(into: $0) }
    XCTAssertEqual(got?.0, 2)
    XCTAssertEqual(got?.1, aAddr)
    // A rule denying the source drops the datagram unless the app sent to it.
    n.policy.setRules([NetRule(.deny, direction: .inbound, prefix: NetPrefix("127.0.0.0/8"))])
    let c = try peer.datagram(app: "peer", on: v4)
    _ = try Array("x".utf8).withUnsafeBytes { try c.sendDatagram($0, to: aAddr) }
    _ = try Array("y".utf8).withUnsafeBytes { try b.sendDatagram($0, to: aAddr) }
    wait(a.fd)
    usleep(50_000)
    let r = try buf.withUnsafeMutableBytes { try a.receiveDatagram(into: $0) }
    XCTAssertEqual(r?.1, bAddr, "reply from a contacted peer passes, stranger dropped")
    XCTAssertEqual(buf[0], UInt8(ascii: "y"))
    XCTAssertNil(try buf.withUnsafeMutableBytes { try a.receiveDatagram(into: $0) })
    XCTAssertGreaterThanOrEqual(n.deniedCount, 1)
    n.policy.setRules([NetRule(.deny, direction: .outbound, ports: 9...9)])
    XCTAssertThrowsError(
      try Array("z".utf8).withUnsafeBytes { try a.sendDatagram($0, to: .loopback(.v4, port: 9)) })
  }

  func testPerAppLimit() throws {
    let p = NetPolicy()
    p.setEntitlements(NetEntitlements(client: true), for: "app")
    let n = HostedNetwork(policy: p, perAppLimit: 2)
    let a = try n.datagram(app: "app", on: v4)
    let b = try n.datagram(app: "app", on: v4)
    XCTAssertThrowsError(try n.datagram(app: "app", on: v4)) {
      XCTAssertEqual($0 as? NetError, .limit)
    }
    a.close()
    XCTAssertNoThrow(try n.datagram(app: "app", on: v4))
    _ = b
  }

  func openFDs() -> Int {
    (0..<256).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
  }
}
