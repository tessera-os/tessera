import Darwin
import Dispatch
import Foundation
import Synchronization
import TarwinArchHosted
import TarwinMMHosted
import TarwinTaskProtocol
import TarwinTaskTransport
import Testing

private final class ExceptionTestBundle {}

private final class FaultSink: HostExceptionSink, @unchecked Sendable {
  let event = DispatchSemaphore(value: 0)
  let observed = Mutex<[HostException]>([])
  var space: HostedAddressSpace?

  func handle(_ exception: HostException) -> HostExceptionDisposition {
    observed.withLock { $0.append(exception) }
    defer { event.signal() }
    do {
      return (try? space?.resumeAfterFileFault(exception)) ?? .terminate
    } catch {
      return .terminate
    }
  }
}

@Test func sandboxedTaskFaultsInFilePages() throws {
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
  sink.space = space
  let stack = try HostedMemoryEntry.anonymous(size: size)
  try space.map(.init(address: stackAddress, size: size, entry: stack, protection: [.read, .write]))
  let code = try [UInt32(0xb940_0001), 0xb900_03e1, 0x1400_0000].withUnsafeBytes {
    try HostedMemoryEntry.sealedCode(size: size, verifiedBytes: $0)
  }
  try space.map(.init(address: codeAddress, size: size, entry: code, protection: [.read, .execute]))
  let backing = HostedFileBacking(size: size) { _, page in
    page[0] = 42
    return page.count
  }
  try space.reserveFile(address: fileAddress, size: size, backing: backing, offset: 0, protection: .read)
  try #require(try child.command(.createThread(
    id: 1, entry: codeAddress, argument: fileAddress, stack: stackAddress + size - 16, tls: stackAddress))
    .get().status == KERN_SUCCESS)
  try #require(try child.command(.resumeThread(id: 1)).get().status == KERN_SUCCESS)
  try #require(sink.event.wait(timeout: .now() + .seconds(5)) == .success)
  let first = try #require(sink.observed.withLock { $0.first })
  #expect(first.kind == .badAccess)
  #expect(first.faultAddress == fileAddress)
  #expect(space.footprint == 3 * size, "Mach exception code: \(first.code), PC: \(first.pc)")
}
