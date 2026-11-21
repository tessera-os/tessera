import Darwin
import Foundation
import XCTest
import TRFS
import TRFSHosted
import TarwinArchHosted
import TarwinBlockHosted
import TarwinDevice
import TarwinFsWire
import TarwinIPC
import TarwinNetHosted
import TarwinReadOnlyFS
import TarwinSyscall
@testable import TarwindKernel

private final class ResourceHost: TarwindSystemVolumeVerifier, @unchecked Sendable {
  var root: [UInt8] = []
  var measurementAccepted = true
  var measured: [[UInt8]] = []
  func bootStage(_ name: String) {}
  func ready() {}
  func console(_ line: String) {}
  func panic(record: [UInt8]) { XCTFail("unexpected panic") }
  func systemVolumeRoot(path: String) throws -> [UInt8] { root }
  func measureSystemVolume(root: [UInt8]) -> Bool { measured.append(root); return measurementAccepted }
}

private struct FolderShares: ReadOnlyShares {
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

private final class FakeProvider: HostDeviceProvider, @unchecked Sendable {
  let kind = "fake"
  let receive: HostPort
  init() throws { receive = try HostPort.receive() }
  func open(slot: UInt32) throws -> HostPort {
    guard slot == 0 else { throw TarwindError.unavailable }
    return try receive.makeSend()
  }
}

final class ResourcesTests: XCTestCase {
  var directory: URL!
  private var host: ResourceHost!
  var config: TarwindConfig {
    .init(diskPath: directory.appendingPathComponent("data.trfs").path,
      systemImagePath: directory.appendingPathComponent("system.trfs").path,
      panicRecordPath: "", taskExecutablePath: "")
  }
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    host = ResourceHost()
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  func testDataWriteShutdownRemountAndRead() throws {
    var file: UInt64 = 0
    let bytes = Array("persistent hosted data".utf8)
    let first = try Tarwind.boot(config, host: host)
    file = try XCTUnwrap(first.withDataVolume { $0.create(1, name: Array("hello".utf8), kind: .file) })
    XCTAssertTrue(try first.withDataVolume { volume in
      bytes.withUnsafeBytes { volume.writePage(file, index: 0, bytes: $0) }
    })
    first.shutdown()
    XCTAssertThrowsError(try first.withDataVolume { $0.snapshot })
    let second = try Tarwind.boot(config, host: host)
    defer { second.shutdown() }
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 16)
    defer { buffer.deallocate() }
    let count = try second.withDataVolume { volume -> Int? in
      guard let snapshot = volume.snapshot,
        case .file(let id) = volume.lookup(1, name: Array("hello".utf8), in: snapshot), id == file else { return nil }
      return volume.readPage(id, index: 0, in: snapshot, into: buffer)
    }
    XCTAssertEqual(count, bytes.count)
    XCTAssertEqual(Array(buffer.prefix(bytes.count)), bytes)
  }

  func testDamagedDiskAndSystemVerificationFailClosed() throws {
    do { _ = try HostedBlockDevice.create(path: config.diskPath, blocks: 64) }
    XCTAssertThrowsError(try Tarwind.boot(config, host: host))
    try FileManager.default.removeItem(atPath: config.diskPath)
    do {
      let system = try HostedTrfsDisk.openData(path: config.systemImagePath, blocks: 64)
      _ = system.withVolume { $0.create(1, name: Array("bin".utf8), kind: .directory) }
      host.root = [UInt8](repeating: 0, count: 32)
      XCTAssertTrue(host.root.withUnsafeMutableBytes { bytes in
        system.withVolume { $0.snapshot!.digest.encode(into: bytes) }
      })
    }
    let kernel = try Tarwind.boot(config, host: host)
    XCTAssertEqual(host.measured, [host.root])
    XCTAssertNil(try kernel.withSystemVolume { $0.create(1, name: Array("forbidden".utf8), kind: .file) })
    kernel.shutdown()
    host.measurementAccepted = false
    XCTAssertThrowsError(try Tarwind.boot(config, host: host))
    host.measurementAccepted = true
    host.root[0] ^= 1
    XCTAssertThrowsError(try Tarwind.boot(config, host: host))
    host.root = []
    XCTAssertThrowsError(try Tarwind.boot(config, host: host))
  }

  func testShareFolderReadThroughServerAndUnshare() throws {
    let kernel = try Tarwind.boot(config, host: host)
    defer { kernel.shutdown() }
    try Data("shared bytes".utf8).write(to: directory.appendingPathComponent("hello"))
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }
    XCTAssertThrowsError(try kernel.shareFolder(name: "invalid", directoryFD: -1, readOnly: true))
    try kernel.shareFolder(name: "shared", directoryFD: fd, readOnly: true)
    XCTAssertNotEqual(fcntl(fd, F_GETFD), -1)
    XCTAssertThrowsError(try kernel.shareFolder(name: "shared", directoryFD: fd, readOnly: false))
    let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 12288, alignment: 4096)
    defer { raw.deallocate() }
    let mapping = try XCTUnwrap(IoRingMapping(initializing: raw, count: 64, stride: 64))
    var session = FsRingSession(volume: 9, epoch: 17, limit: 80,
      requests: mapping.endpoint(completion: false, producer: true)!,
      replies: mapping.endpoint(completion: true, producer: false)!)!
    let server = try kernel.makeFolderServer(name: "shared", epoch: 17,
      requests: mapping.endpoint(completion: false, producer: false)!,
      replies: mapping.endpoint(completion: true, producer: true)!)
    var shares = FolderShares()
    func request(_ op: FsOp, node: UInt64, input: [UInt8], capacity: UInt32) throws -> FsStatus {
      shares.input = input; shares.output = []
      let result = session.submit(op, node: VolumeNode(volume: 9, node: node),
        other: VolumeNode(volume: 0, node: 0), offset: 0, input: input.isEmpty ? 0 : 1,
        inputBytes: UInt32(input.count), output: capacity == 0 ? 0 : 2, outputBytes: capacity,
        resolveShare: { id in FsShare(volume: 9, id: id, backing: 10, offset: id * 100,
          length: id == 1 ? UInt32(input.count) : capacity, writable: id == 2) })
      guard case .ring(.transferred) = result else { XCTFail("request rejected"); return .invalid }
      XCTAssertEqual(server.step(shares: &shares, signalSpace: {}, signalReply: {}), .replied)
      var status: FsStatus?
      XCTAssertEqual(session.poll(signalSpace: {}, revoke: { _ in true }, deliver: { _, reply in status = reply.status }), .completed)
      return try XCTUnwrap(status)
    }
    XCTAssertEqual(try request(.lookup, node: 1, input: Array("hello".utf8), capacity: 8), .ok)
    let node = shares.output.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    XCTAssertEqual(try request(.read, node: node, input: [], capacity: 64), .ok)
    XCTAssertEqual(shares.output, Array("shared bytes".utf8))
    XCTAssertEqual(try request(.write, node: node, input: [1], capacity: 0), .readOnly)
    kernel.unshareFolder(name: "shared")
    XCTAssertEqual(server.step(shares: &shares, signalSpace: {}, signalReply: {}), .stopped)
    XCTAssertNotEqual(fcntl(fd, F_GETFD), -1)
    kernel.unshareFolder(name: "shared")
  }

  func awaitReady(_ socket: TarwindSocket, mask: UInt64, kernel: Tarwind, process: TarwindProcessID) throws {
    var registers = TarwinCallRegisters(number: TarwinCall.objectWait,
      arguments: CallRegisters(socket.readinessHandle, mask, UInt64.max))
    switch kernel.gate.call(process: process, registers: &registers) {
    case .completed(let result): XCTAssertEqual(result.status, 0)
    case .blocked(let continuation):
      let deadline = Date().addingTimeInterval(3)
      var completion: CallResult?
      while completion == nil && Date() < deadline {
        completion = kernel.gate.completion(continuation)
        if completion == nil { Thread.sleep(forTimeInterval: 0.001) }
      }
      XCTAssertEqual(try XCTUnwrap(completion).status, 0)
    }
  }

  func testLoopbackEchoReadinessReachesObjectWait() throws {
    let kernel = try Tarwind.boot(config, host: host)
    defer { kernel.shutdown() }
    let process = kernel.createKernelProcess(name: "network")
    XCTAssertThrowsError(try kernel.connectNetwork(process: process, to: .loopback(.v4, port: 9))) {
      guard case NetError.denied = $0 else { return XCTFail("\($0)") }
    }
    XCTAssertEqual(kernel.networkDecisions(process: process).last?.socketCreated, false)
    try kernel.grant(process: process, .network(NetPolicy(rules: [NetRule(.allow)])))
    let listener = try kernel.listenNetwork(process: process, on: .loopback(.v4))
    let client = try kernel.connectNetwork(process: process, to: XCTUnwrap(listener.local))
    try awaitReady(listener, mask: 1, kernel: kernel, process: process)
    let server = try kernel.acceptNetwork(listener)
    try awaitReady(client, mask: 2, kernel: kernel, process: process)
    XCTAssertNil(client.connectResult()!)
    var waitRegisters = TarwinCallRegisters(number: TarwinCall.objectWait,
      arguments: CallRegisters(server.readinessHandle, 1, .max))
    guard case .blocked(let waiting) = kernel.gate.call(process: process, registers: &waitRegisters) else {
      return XCTFail("empty stream must block without retaining a host thread")
    }
    let payload = Array("echo".utf8)
    XCTAssertEqual(try payload.withUnsafeBytes { try client.send($0) }, .bytes(4))
    let deadline = Date().addingTimeInterval(3)
    var completion: CallResult?
    while completion == nil && Date() < deadline {
      completion = kernel.gate.completion(waiting)
      if completion == nil { Thread.sleep(forTimeInterval: 0.001) }
    }
    XCTAssertEqual(try XCTUnwrap(completion).status, 0)
    var bytes = [UInt8](repeating: 0, count: 4)
    XCTAssertEqual(try bytes.withUnsafeMutableBytes { try server.receive(into: $0) }, .bytes(4))
    XCTAssertEqual(bytes, payload)
    XCTAssertEqual(try bytes.withUnsafeBytes { try server.send($0) }, .bytes(4))
    try awaitReady(client, mask: 1, kernel: kernel, process: process)
    bytes = [UInt8](repeating: 0, count: 4)
    XCTAssertEqual(try bytes.withUnsafeMutableBytes { try client.receive(into: $0) }, .bytes(4))
    XCTAssertEqual(bytes, payload)
    waitRegisters = TarwinCallRegisters(number: TarwinCall.objectWait,
      arguments: CallRegisters(server.readinessHandle, 1, .max))
    guard case .blocked(let cancelled) = kernel.gate.call(process: process, registers: &waitRegisters) else {
      return XCTFail("empty stream must block before close")
    }
    server.close()
    XCTAssertNotEqual(try XCTUnwrap(kernel.gate.completion(cancelled)).status, 0)
    client.close(); listener.close()
    XCTAssertThrowsError(try payload.withUnsafeBytes { try client.send($0) })
    kernel.shutdown()
    XCTAssertThrowsError(try kernel.listenNetwork(process: process, on: .loopback(.v4)))
  }

  func testRegisteredProviderOpensUsablePortForKernelProcess() throws {
    let registry = HostDeviceRegistry()
    let provider = try FakeProvider()
    registry.register(provider)
    let kernel = try Tarwind.boot(config, host: host, devices: registry)
    defer { kernel.shutdown() }
    let process = kernel.createKernelProcess(name: "driver")
    try kernel.grant(process: process, .device(kind: "fake"))
    let send = try kernel.openHostDevice(process: process, kind: "fake", slot: 0)
    let events = try HostEventQueue()
    let token = try events.registerMachPort(provider.receive)
    var message = mach_msg_header_t()
    message.msgh_bits = UInt32(MACH_MSG_TYPE_COPY_SEND)
    message.msgh_size = mach_msg_size_t(MemoryLayout<mach_msg_header_t>.size)
    message.msgh_remote_port = send.rawName
    XCTAssertEqual(withExtendedLifetime(send) { mach_msg(&message, MACH_SEND_MSG, message.msgh_size, 0, 0, 0, 0) }, KERN_SUCCESS)
    XCTAssertEqual(try events.wait(timeoutNanos: 1_000_000_000).first?.token, token)
    try events.cancel(token)
    XCTAssertThrowsError(try { let port = try kernel.openHostDevice(process: process, kind: "fake", slot: 99); _ = port.rawName }())
    XCTAssertThrowsError(try { let port = try kernel.openHostDevice(process: process, kind: "missing", slot: 0); _ = port.rawName }())
    kernel.shutdown()
    XCTAssertThrowsError(try { let port = try kernel.openHostDevice(process: process, kind: "fake", slot: 0); _ = port.rawName }())
  }
}
