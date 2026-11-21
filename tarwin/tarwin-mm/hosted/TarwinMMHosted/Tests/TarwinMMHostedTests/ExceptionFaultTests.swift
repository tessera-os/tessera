import Darwin
import Dispatch
import Foundation
import Synchronization
import TRFSHosted
import TarwinArchHosted
import TarwinMMHosted
import TarwinTaskProtocol
import TarwinTaskTransport
import Testing

private final class ExceptionTestBundle {}

private final class FaultSink: HostExceptionSink, @unchecked Sendable {
  let event = DispatchSemaphore(value: 0)
  let observed = Mutex<[HostException]>([])
  private let lock = NSLock()
  private var space: HostedAddressSpace?

  func install(space: HostedAddressSpace) {
    lock.withLock { self.space = space }
  }

  func handle(_ exception: HostException) -> HostExceptionDisposition {
    observed.withLock { $0.append(exception) }
    defer { event.signal() }
    return lock.withLock {
      return (try? space?.resumeAfterFileFault(exception)) ?? .terminate
    }
  }
}

@Test func sandboxedTaskResumesAfterLiveTrfsFault() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("tarwin-live-trfs-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = try HostedTrfsDisk.imagePath(name: "System", home: directory.path)
  var bootRoot = [UInt8](repeating: 0, count: 32)
  let file: UInt64
  do {
    let disk = try HostedTrfsDisk.openData(path: path, blocks: 1 << 14)
    file = try #require(disk.withVolume {
      $0.create(1, name: Array("fault-data".utf8), kind: .file)
    })
    let payload: [UInt8] = [42, 0, 0, 0]
    try #require(payload.withUnsafeBytes { bytes in
      disk.withVolume { $0.writePage(file, index: 0, bytes: bytes) }
    })
    let root = try #require(disk.withVolume { $0.snapshot })
    try #require(bootRoot.withUnsafeMutableBytes { root.digest.encode(into: $0) })
  }
  let disk = try bootRoot.withUnsafeBytes {
    try HostedTrfsDisk.openSystem(path: path, bootSetRoot: $0) { _ in true }
  }
  let root = try #require(disk.withVolume { $0.snapshot })
  let length = try #require(disk.withVolume { $0.length(file, in: root) })
  let backing = HostedFileBacking.trfsSnapshot(size: length) { block, buffer in
    disk.withVolume { $0.readPage(file, index: block, in: root, into: buffer) ?? 0 }
  }

  let executable = Bundle(for: ExceptionTestBundle.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("tarwin-task")
  let sink = FaultSink()
  let exceptions = try HostExceptionPort(sink: sink)
  defer { withExtendedLifetime(exceptions) {} }
  let child = try withExtendedLifetime(exceptions.makeSend()) {
    try TaskSpawner.spawn(executable: executable.path, exceptionPort: $0.rawName)
  }
  defer { kill(child.pid, SIGKILL); waitpid(child.pid, nil, 0) }
  let transport = HostedTaskCommandMappings(task: child) { _ in kill(child.pid, SIGKILL) }
  let size = hostedPageSize
  let codeAddress = TaskWindow.base
  let stackAddress = codeAddress + size
  let fileAddress = stackAddress + size
  let space = try HostedAddressSpace(window: TaskWindow.base..<(TaskWindow.base + TaskWindow.size),
    task: transport)
  sink.install(space: space)
  let stack = try HostedMemoryEntry.anonymous(size: size)
  let result = try stack.mapLocally(protection: .read)
  try space.map(.init(address: stackAddress, size: size, entry: stack, protection: [.read, .write]))
  let code = try [UInt32(0xb940_0001), 0xb900_03e1, 0x1400_0000].withUnsafeBytes {
    try HostedMemoryEntry.sealedCode(size: size, verifiedBytes: $0)
  }
  try space.map(.init(address: codeAddress, size: size, entry: code, protection: [.read, .execute]))
  try space.reserveFile(address: fileAddress, size: size, backing: backing, offset: 0, protection: .read)
  #expect(space.footprint == 2 * size)
  try #require(try child.command(.createThread(
    id: 1, entry: codeAddress, argument: fileAddress, stack: stackAddress + size - 16, tls: stackAddress))
    .get().status == KERN_SUCCESS)
  try #require(try child.command(.resumeThread(id: 1)).get().status == KERN_SUCCESS)
  try #require(sink.event.wait(timeout: .now() + .seconds(5)) == .success)
  let first = try #require(sink.observed.withLock { $0.first })
  #expect(first.kind == .badAccess)
  #expect(first.code == UInt64(KERN_PROTECTION_FAILURE))
  #expect(first.faultAddress == fileAddress)
  #expect(space.footprint == 3 * size, "Mach exception code: \(first.code), PC: \(first.pc)")
  let deadline = DispatchTime.now() + .seconds(5)
  var value: UInt32 = 0
  repeat {
    var bytesRead: UInt64 = 0
    let status = withUnsafeMutablePointer(to: &value) {
      mach_vm_read_overwrite(
        mach_task_self_, result.address + size - 16, UInt64(MemoryLayout<UInt32>.size),
        UInt64(UInt(bitPattern: $0)), &bytesRead)
    }
    try #require(status == KERN_SUCCESS)
    if value != 0 { break }
    usleep(1_000)
  } while DispatchTime.now() < deadline
  #expect(value == 42)
}
