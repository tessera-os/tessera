import Darwin
import Foundation
import TarwindKernel
import TarwinTaskTransport

private final class PreflightHost: TarwindSystemVolumeVerifier, @unchecked Sendable {
  // Pin of trfs/tests/fixtures/make-system-image.swift; never an app or boot signer.
  private let fixtureRoot: [UInt8] = [
    0xac, 0xf8, 0xe3, 0x29, 0xe9, 0x80, 0xf5, 0xea, 0x25, 0x30, 0xad, 0x42, 0xc2, 0x9d, 0x53, 0x43,
    0xb0, 0x5a, 0x73, 0x39, 0xf3, 0x18, 0x83, 0xc6, 0xd6, 0x09, 0x81, 0xd3, 0x6e, 0x23, 0x21, 0xe3,
  ]
  private let lock = NSLock()
  private var booted = false
  private var measured = false
  var isReady: Bool { lock.withLock { booted && measured } }
  func systemVolumeRoot(path: String) throws -> [UInt8] { fixtureRoot }
  func measureSystemVolume(root: [UInt8]) -> Bool {
    lock.withLock { measured = root == fixtureRoot; return measured }
  }
  func bootStage(_ name: String) { print("stage:", name) }
  func ready() { lock.withLock { booted = true } }
  func console(_ line: String) { print("kernel:", line) }
  func panic(record: [UInt8]) { FileHandle.standardError.write(Data("kernel panic\n".utf8)); exit(1) }
}

private enum RunnerError: Error { case didNotBoot, terminateRejected, abnormalExit, timeout }

private func preflight(task: String, system: String) throws {
  let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: dir) }
  let host = PreflightHost()
  let daemon = try Tarwind.boot(TarwindConfig(diskPath: dir.appending(path: "data.trfs").path,
    systemImagePath: system, panicRecordPath: dir.appending(path: "panic").path,
    taskExecutablePath: task), host: host)
  defer { daemon.shutdown() }
  guard host.isReady else { throw RunnerError.didNotBoot }

  let child = try TaskSpawner.spawn(executable: task)
  var reaped = false
  defer {
    if !reaped {
      kill(child.pid, SIGKILL)
      while waitpid(child.pid, nil, 0) == -1 && errno == EINTR {}
    }
  }
  guard try child.command(.terminate).get().status == KERN_SUCCESS else {
    throw RunnerError.terminateRejected
  }
  let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
  while DispatchTime.now().uptimeNanoseconds < deadline {
    var status: Int32 = -1
    let pid = waitpid(child.pid, &status, WNOHANG)
    if pid == child.pid {
      reaped = true
      guard status == 0 else { throw RunnerError.abnormalExit }
      return
    }
    if pid < 0 && errno != EINTR {
      if errno == ECHILD { reaped = true }
      throw RunnerError.abnormalExit
    }
    usleep(1000)
  }
  throw RunnerError.timeout
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "run" {
  FileHandle.standardError.write(Data("NOT RUN: no verified application launch/exit adapter on this revision.\n".utf8))
  exit(69)
}
guard args.count == 3 && args[0] == "preflight" else {
  FileHandle.standardError.write(Data("usage: hosted-io-e2e preflight TASK_EXECUTABLE SYSTEM_IMAGE\n".utf8))
  exit(64)
}
do {
  try preflight(task: args[1], system: args[2])
  print("Preflight: kernel ready; fixture root measured; task checked in and exited. No guest application was launched.")
} catch {
  FileHandle.standardError.write(Data("preflight failed: \(error)\n".utf8))
  exit(1)
}
