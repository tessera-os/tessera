import Darwin
import Foundation
@testable import HostedIOChecks
import TarwindKernel
import TRFSHosted
import TarwinNetHosted
import XCTest

final class ProofTests: XCTestCase {
  private let challenge = Array(UInt8(0)..<32)

  func testDiskIsCheckedAfterReopen() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appending(path: "data.trfs").path
    XCTAssertThrowsError(try DiskProof.verify(path: path, challenge: challenge))
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    do {
      let disk = try HostedTrfsDisk.openData(path: path, blocks: 64)
      let file = try XCTUnwrap(disk.withVolume { $0.create(1, name: Array(DiskProof.filename.utf8), kind: .file) })
      XCTAssertTrue(disk.withVolume { v in challenge.withUnsafeBytes { v.writePage(file, index: 0, bytes: $0) } })
      try withExtendedLifetime(disk) {
        XCTAssertThrowsError(try DiskProof.verify(path: path, challenge: challenge))
      }
    }
    try DiskProof.verify(path: path, challenge: challenge)
    XCTAssertThrowsError(try DiskProof.verify(path: path, challenge: challenge.reversed())) {
      XCTAssertEqual($0 as? ProofError, .wrongFile)
    }
    do {
      let disk = try HostedTrfsDisk.openData(path: path, blocks: 64)
      try disk.withVolume { v in
        let root = try XCTUnwrap(v.snapshot)
        guard case .file(let id) = v.lookup(1, name: Array(DiskProof.filename.utf8), in: root)
        else { return XCTFail("missing file") }
        XCTAssertTrue((challenge + [0]).withUnsafeBytes { v.writePage(id, index: 0, bytes: $0) })
      }
    }
    XCTAssertThrowsError(try DiskProof.verify(path: path, challenge: challenge)) {
      XCTAssertEqual($0 as? ProofError, .wrongFile)
    }
  }

  private func connect(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProofError.system(errno) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = port.bigEndian
    let result = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { let e = errno; close(fd); throw ProofError.system(e) }
    return fd
  }

  func testWitnessKnownGoodAndWrongReply() throws {
    for corrupt in [false, true] {
      let witness = try LoopbackWitness(allowed: 0, denied: 0)
      let client = try connect(witness.allowedPort)
      let finished = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        defer { close(client); finished.signal() }
        var data = [UInt8](repeating: 0, count: 32)
        guard recv(client, &data, 32, MSG_WAITALL) == 32 else { return }
        if corrupt { data[31] ^= 1 }
        for byte in data {
          var b = byte
          guard send(client, &b, 1, 0) == 1 else { return }
        }
      }
      if corrupt {
        XCTAssertThrowsError(try witness.exchange(challenge: challenge)) {
          XCTAssertEqual($0 as? ProofError, .wrongReply)
        }
      } else {
        try witness.exchange(challenge: challenge)
      }
      XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
      try witness.checkDeniedPort()
      let sentinel = try connect(witness.deniedPort)
      defer { close(sentinel) }
      XCTAssertThrowsError(try witness.checkDeniedPort()) {
        XCTAssertEqual($0 as? ProofError, .deniedConnection)
      }
    }
  }

  func testNoGuestCannotPass() throws {
    let witness = try LoopbackWitness(allowed: 0, denied: 0)
    XCTAssertThrowsError(try witness.exchange(challenge: challenge, timeoutMilliseconds: 20)) {
      XCTAssertEqual($0 as? ProofError, .timeout)
    }
  }

  func testPolicyGrantsOnlyTheFixtureOutboundPeer() {
    let grants = RunProof.launchGrants()
    guard grants.count == 2, case .namespace(.data, "/", let rights) = grants[0],
      case .network(let policy) = grants[1] else { return XCTFail("unexpected launch grants") }
    XCTAssertEqual(rights, [.read, .write, .create])
    let app = RunProof.appID
    func verdict(_ id: String, _ host: String, _ port: UInt16, _ proto: NetProtocol = .tcp,
      _ direction: NetDirection = .outbound) -> NetVerdict {
      policy.check(NetFlow(app: id, proto: proto, direction: direction, address: NetAddress(host, port: port)!))
    }
    XCTAssertEqual(verdict(app, "127.0.0.1", 43871), .allow)
    XCTAssertEqual(verdict(app, "127.0.0.1", 43872), .deny("rule"))
    XCTAssertEqual(verdict("another-app", "127.0.0.1", 43871), .deny("rule"))
    XCTAssertEqual(verdict(app, "127.0.0.2", 43871), .deny("rule"))
    XCTAssertEqual(verdict(app, "127.0.0.1", 43871, .udp), .deny("rule"))
    XCTAssertEqual(verdict(app, "127.0.0.1", 43871, .tcp, .listen), .deny("rule"))
  }

  func testOrderedSocketEvidenceForVerifiedClient() {
    // Model controls only; production records come from the per-process kernel journal.
    func record(_ port: UInt16, _ verdict: NetVerdict, _ created: Bool,
      id: String? = RunProof.appID, proto: NetProtocol = .tcp, reason: String = "rule",
      host: String = "127.0.0.1") -> SocketObservation {
      SocketObservation(appID: id, proto: proto, endpoint: NetAddress(host, port: port)!,
        verdict: verdict, reason: reason, socketCreated: created)
    }
    let allow = record(43871, .allow, true, reason: "policy")
    let deny = record(43872, .deny("rule"), false)
    XCTAssertTrue(RunProof.matchesSockets([allow, deny]))
    for invalid in [[], [allow], [deny, allow], [allow, deny, deny],
      [record(43871, .allow, false), deny],
      [allow, record(43872, .deny("rule"), true)],
      [allow, record(43872, .allow, false, reason: "host failure")],
      [allow, record(43872, .deny("rule"), false, id: nil)],
      [allow, record(43872, .deny("rule"), false, id: "another-app")],
      [allow, record(43872, .deny("rule"), false, proto: .udp)],
      [allow, record(43872, .deny("unknown app"), false)],
      [allow, record(43872, .deny("rule"), false, reason: "unknown app")],
      [allow, record(43872, .deny("rule"), false, host: "127.0.0.2")],
      [allow, record(43871, .deny("rule"), false)]] {
      XCTAssertFalse(RunProof.matchesSockets(invalid))
    }
  }
}
