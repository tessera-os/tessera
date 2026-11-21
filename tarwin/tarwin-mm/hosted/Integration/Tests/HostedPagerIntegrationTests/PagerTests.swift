import Darwin
import Dispatch
import Foundation
import Synchronization
import TRFSHosted
import TarwinArchHosted
import TarwinMMHosted
import TarwinTaskProtocol
import TarwinTaskTransport
import TarwindKernel
import Testing

private final class TestBundle {}

private final class TestHost: TarwindSystemVolumeVerifier {
  let root: [UInt8]

  init(root: [UInt8]) { self.root = root }

  func bootStage(_ name: String) {}
  func ready() {}
  func console(_ line: String) {}
  func panic(record: [UInt8]) { Issue.record("Tarwind panicked") }
  func systemVolumeRoot(path: String) throws -> [UInt8] { root }
  func measureSystemVolume(root: [UInt8]) -> Bool { self.root == root }
}

private final class PagerBinding: @unchecked Sendable {
  private let lock = NSLock()
  private var space: HostedAddressSpace?

  func install(_ space: HostedAddressSpace) {
    lock.withLock { self.space = space }
  }

  func resume(_ exception: HostException) throws -> HostExceptionDisposition? {
    try lock.withLock { try space?.resumeAfterFileFault(exception) }
  }
}

@Test func tarwindResumesSandboxedTaskAfterTrfsFault() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("tarwind-hosted-pager-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let path = try HostedTrfsDisk.imagePath(name: "System", home: directory.path)
  var pin = [UInt8](repeating: 0, count: 32)
  let file: UInt64
  do {
    let disk = try HostedTrfsDisk.openData(path: path, blocks: 1 << 14)
    file = try #require(disk.withVolume { $0.create(1, name: Array("payload".utf8), kind: .file) })
    let payload: [UInt8] = [42, 0, 0, 0]
    try #require(payload.withUnsafeBytes { bytes in
      disk.withVolume { $0.writePage(file, index: 0, bytes: bytes) }
    })
    let root = try #require(disk.withVolume { $0.snapshot })
    try #require(pin.withUnsafeMutableBytes { root.digest.encode(into: $0) })
  }

  let executable = Bundle(for: TestBundle.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("tarwin-task").path
  let kernel = try Tarwind.boot(.init(
    diskPath: directory.appendingPathComponent("Data").path, systemImagePath: path,
    panicRecordPath: "", taskExecutablePath: executable), host: TestHost(root: pin))
  defer { kernel.shutdown() }
  let root = try #require(try kernel.withSystemVolume { $0.snapshot })
  let length = try #require(try kernel.withSystemVolume { $0.length(file, in: root) })
  let backing = HostedFileBacking.trfsSnapshot(size: length) { [weak kernel] block, buffer in
    guard let kernel else { throw HostedFaultError.incompleteRead }
    return try kernel.withSystemVolume {
      $0.readPage(file, index: block, in: root, into: buffer) ?? 0
    }
  }
  let process = kernel.createKernelProcess(name: "trfs-pager")
  let binding = PagerBinding()
  let faults = Mutex<[UInt64]>([])
  let page = hostedPageSize
  let stackAddress = TaskWindow.base + page
  let faultAddress = stackAddress + page
  let send = try kernel.makeExceptionSendRight(process: process) { id, exception in
    guard id == process, exception.faultAddress == faultAddress else { return nil }
    faults.withLock { $0.append(exception.code) }
    return try binding.resume(exception)
  }
  let task = try withExtendedLifetime(send) {
    try TaskSpawner.spawn(executable: executable, exceptionPort: $0.rawName)
  }
  defer { kill(task.pid, SIGKILL); waitpid(task.pid, nil, 0) }
  let mappings = HostedTaskCommandMappings(task: task) { _ in kill(task.pid, SIGKILL) }
  let space = try HostedAddressSpace(
    window: TaskWindow.base..<(TaskWindow.base + TaskWindow.size), task: mappings)
  binding.install(space)

  let stack = try HostedMemoryEntry.anonymous(size: page)
  let result = try stack.mapLocally(protection: .read)
  try space.map(.init(address: stackAddress, size: page, entry: stack, protection: [.read, .write]))
  let code = try [UInt32(0xb940_0001), 0xb900_03e1, 0x1400_0000].withUnsafeBytes {
    try HostedMemoryEntry.sealedCode(size: page, verifiedBytes: $0)
  }
  try space.map(.init(address: TaskWindow.base, size: page, entry: code, protection: [.read, .execute]))
  try space.reserveFile(address: faultAddress, size: page, backing: backing, offset: 0, protection: .read)
  #expect(space.footprint == 2 * page)
  try #require(try task.command(.createThread(id: 1, entry: TaskWindow.base,
    argument: faultAddress, stack: stackAddress + page - 16, tls: stackAddress))
    .get().status == KERN_SUCCESS)
  try #require(try task.command(.resumeThread(id: 1)).get().status == KERN_SUCCESS)

  let deadline = DispatchTime.now() + .seconds(5)
  var value: UInt32 = 0
  repeat {
    var bytesRead: UInt64 = 0
    let status = withUnsafeMutablePointer(to: &value) {
      mach_vm_read_overwrite(mach_task_self_, result.address + page - 16,
        UInt64(MemoryLayout<UInt32>.size), UInt64(UInt(bitPattern: $0)), &bytesRead)
    }
    try #require(status == KERN_SUCCESS)
    if value != 0 { break }
    usleep(1_000)
  } while DispatchTime.now() < deadline
  #expect(value == 42)
  #expect(faults.withLock { $0 } == [UInt64(KERN_PROTECTION_FAILURE)])
  #expect(space.footprint == 3 * page)
  #expect(kernel.containsProcess(process))

  let reclaimed = try HostedJetsam.handle(.warning,
    addressSpaces: [.init(id: 1, band: 6, limit: 0, space: space)],
    signal: { _, _ in }, reclaimed: { space.footprint == 2 * page },
    terminate: { _ in Issue.record("unexpected jetsam") })
  #expect(reclaimed == .noAction)
  #expect(space.footprint == 2 * page)

  let nextStack = stackAddress + page - 32
  try #require(try task.command(.createThread(id: 2, entry: TaskWindow.base,
    argument: faultAddress, stack: nextStack, tls: stackAddress))
    .get().status == KERN_SUCCESS)
  try #require(try task.command(.resumeThread(id: 2)).get().status == KERN_SUCCESS)
  let refillDeadline = DispatchTime.now() + .seconds(5)
  value = 0
  repeat {
    var bytesRead: UInt64 = 0
    let status = withUnsafeMutablePointer(to: &value) {
      mach_vm_read_overwrite(mach_task_self_, result.address + page - 32,
        UInt64(MemoryLayout<UInt32>.size), UInt64(UInt(bitPattern: $0)), &bytesRead)
    }
    try #require(status == KERN_SUCCESS)
    if value != 0 { break }
    usleep(1_000)
  } while DispatchTime.now() < refillDeadline
  #expect(value == 42)
  #expect(faults.withLock { $0 } == Array(repeating: UInt64(KERN_PROTECTION_FAILURE), count: 2))
  #expect(space.footprint == 3 * page)
  #expect(kernel.containsProcess(process))
}
