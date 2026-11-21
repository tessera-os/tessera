import Foundation
import TarwinArchHosted
import TarwinNetHosted
import TarwinObject
import XCTest
@testable import TarwindKernel

final class GrantsTests: XCTestCase {
  func withKernel(hooks: TarwindLaunchHooks? = nil, _ body: (Tarwind) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let kernel = try Tarwind.boot(.init(diskPath: directory.appendingPathComponent("disk").path,
      systemImagePath: directory.appendingPathComponent("system").path,
      panicRecordPath: "panic", taskExecutablePath: "task"), host: RecordingHost(),
      devices: HostDeviceRegistry(), hooks: hooks)
    defer { kernel.shutdown() }
    try body(kernel)
  }

  func testNoAmbientNetworkAndBoundedDecisions() throws {
    try withKernel { kernel in
      let denied = kernel.createKernelProcess(name: "same")
      let allowed = kernel.createKernelProcess(name: "same")
      XCTAssertTrue(kernel.networkDecisions(process: denied).isEmpty)
      for _ in 0..<65 {
        XCTAssertThrowsError(try kernel.connectNetwork(process: denied, to: .loopback(.v4, port: 9))) {
          guard case NetError.denied = $0 else { return XCTFail("\($0)") }
        }
      }
      XCTAssertTrue(kernel.state.sockets.isEmpty)
      let decisions = kernel.networkDecisions(process: denied)
      XCTAssertEqual(decisions.count, 64)
      XCTAssertTrue(decisions.allSatisfy { !$0.socketCreated && $0.verdict != .allow && $0.appID == nil })
      kernel.state.lock.withLock {
        kernel.state.processes[allowed]!.verifiedAppID = "org.tessera.network-test"
        kernel.state.processes[allowed]!.networkEntitlements = NetEntitlements(client: true)
      }
      let policy = NetPolicy()
      try kernel.grant(process: allowed, .network(policy))
      let listener = try kernel.listenNetwork(process: allowed, on: .loopback(.v4))
      defer { listener.close() }
      let socket = try kernel.connectNetwork(process: allowed, to: XCTUnwrap(listener.local))
      defer { socket.close() }
      XCTAssertEqual(kernel.networkDecisions(process: allowed).last?.verdict, .allow)
      XCTAssertEqual(kernel.networkDecisions(process: allowed).last?.socketCreated, true)
      XCTAssertEqual(kernel.networkDecisions(process: allowed).last?.appID, "org.tessera.network-test")
      XCTAssertEqual(kernel.networkDecisions(process: denied).count, 64)
      XCTAssertThrowsError(try kernel.grant(process: allowed, .network(policy)))
      kernel.shutdown()
      XCTAssertTrue(kernel.networkDecisions(process: allowed).isEmpty)
      XCTAssertTrue(kernel.networkDecisions(process: denied).isEmpty)
      XCTAssertEqual(policy.check(NetFlow(app: "org.tessera.network-test", proto: .tcp,
        direction: .outbound, address: .loopback(.v4, port: 9))), .deny("unknown app"))
    }
  }

  func testOptionalHooksAndTrapAuthorizationValidation() throws {
    try withKernel { XCTAssertNil($0.state.hooks) }
    let hooks = TarwindLaunchHooks(rewrite: { _, code, _, _, _ in (code, Data(), [:]) },
      authorizeTrap: { _, _ in nil }, enroll: { _, _, _ in })
    try withKernel(hooks: hooks) { XCTAssertNotNil($0.state.hooks) }
    XCTAssertNotNil(TrapAuthorization(threadID: 1, originalPC: 0x1000,
      resumePC: 0x2004, number: 1, arguments: .init(repeating: 0, count: 8)))
    XCTAssertNil(TrapAuthorization(threadID: 1, originalPC: 0x1000,
      resumePC: 0x2004, number: 1, arguments: []))
    XCTAssertNil(TrapAuthorization(threadID: 0, originalPC: 0x1000,
      resumePC: 0x2004, number: 1, arguments: .init(repeating: 0, count: 8)))
    XCTAssertNil(TrapAuthorization(threadID: 1, originalPC: 0x1001,
      resumePC: 0x2004, number: 1, arguments: .init(repeating: 0, count: 8)))
  }

  func testNamespaceRightsAndSystemReadOnly() throws {
    try withKernel { kernel in
      let process = kernel.createKernelProcess(name: "rights")
      let handle = try XCTUnwrap(kernel.grant(process: process,
        .namespace(volume: .data, path: "/", rights: [.read, .write])))
      kernel.state.lock.withLock {
        guard case .accessDenied = kernel.state.processes[process]!.table.pointee.reader
          .pinWithinEpoch(handle, kind: TarwinKind.node, need: TarwindRights.create.rawValue)
        else { return XCTFail("write must not imply create") }
      }
      for right: TarwindRights in [.write, .create, .delete] {
        XCTAssertThrowsError(try kernel.grant(process: process,
          .namespace(volume: .system, path: "/", rights: right))) {
          guard case TarwindGrantError.readOnly = $0 else { return XCTFail("\($0)") }
        }
      }
      for path in ["relative", "/../escape", "/./escape", "/bad\0name"] {
        XCTAssertThrowsError(try kernel.grant(process: process,
          .namespace(volume: .data, path: path, rights: .read)))
      }
      XCTAssertThrowsError(try kernel.grant(process: process,
        .namespace(volume: .data, path: "/", rights: .init(rawValue: 1 << 32))))
      XCTAssertThrowsError(try kernel.grant(process: process,
        .namespace(volume: .shared("missing"), path: "/", rights: .create)))
    }
  }

  func testDatagramWrappers() throws {
    try withKernel { kernel in
      let process = kernel.createKernelProcess(name: "udp")
      try kernel.grant(process: process, .network(NetPolicy(rules: [NetRule(.allow)])))
      let a = try kernel.datagramNetwork(process: process, on: .loopback(.v4))
      let b = try kernel.datagramNetwork(process: process, on: .loopback(.v4))
      defer { a.close(); b.close() }
      var bytes = [UInt8](repeating: 0, count: 8)
      XCTAssertNil(try bytes.withUnsafeMutableBytes { try b.receiveDatagram(into: $0) })
      XCTAssertEqual(try [UInt8]("udp".utf8).withUnsafeBytes {
        try a.sendDatagram($0, to: XCTUnwrap(b.local))
      }, .bytes(3))
      let deadline = Date().addingTimeInterval(1)
      var result: (Int, NetAddress)?
      repeat { result = try bytes.withUnsafeMutableBytes { try b.receiveDatagram(into: $0) } }
      while result == nil && Date() < deadline
      XCTAssertEqual(result?.0, 3)
      XCTAssertEqual(Array(bytes.prefix(3)), Array("udp".utf8))
      b.close()
      XCTAssertThrowsError(try bytes.withUnsafeMutableBytes { try b.receiveDatagram(into: $0) })
    }
  }

  func testMissingDiskFormatsButExistingInvalidDiskIsNotOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("disk")
    let config = TarwindConfig(diskPath: path.path, systemImagePath: directory.appendingPathComponent("system").path,
      panicRecordPath: "panic", taskExecutablePath: "task")
    let created = try Tarwind.boot(config, host: RecordingHost())
    created.shutdown()
    let remounted = try Tarwind.boot(config, host: RecordingHost())
    remounted.shutdown()
    try FileManager.default.removeItem(at: path)
    for count in [32, 8192] {
      var bytes = Data(repeating: 0, count: count)
      bytes.replaceSubrange(0..<10, with: Data("TRFSDISK v1".utf8))
      try bytes.write(to: path)
      XCTAssertThrowsError(try Tarwind.boot(config, host: RecordingHost())) {
        XCTAssertEqual(String(describing: $0), "disk at \(path.path) is not a TRFS volume")
      }
      XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
  }
}
