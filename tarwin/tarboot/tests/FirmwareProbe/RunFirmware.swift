import Darwin
import Foundation

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func check() throws {
  guard CommandLine.arguments.count == 4 else {
    throw Failure("expected architecture, work directory and CODE.fd")
  }
  let a = CommandLine.arguments[1]
  let d = CommandLine.arguments[2]
  let code = CommandLine.arguments[3]
  let serial = d + "/console.log"
  let monitor = d + "/monitor.log"
  let input = Pipe()
  let fm = FileManager.default
  fm.createFile(atPath: monitor, contents: nil)
  let qmp = try FileHandle(forWritingTo: URL(fileURLWithPath: monitor))
  defer { try? qmp.close() }
  let machine =
    a == "x86_64"
    ? ["-machine", "q35"]
    : (a == "aarch64"
      ? ["-machine", "virt,gic-version=3", "-cpu", "cortex-a72"] : ["-machine", "virt"])
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments =
    ["qemu-system-" + a] + machine + [
      "-m", "512", "-smp", "1", "-display", "none",
      "-serial", "file:" + serial, "-monitor", "none", "-qmp", "stdio", "-nic", "none",
      "-drive", "if=pflash,format=raw,readonly=on,file=" + code, "-drive",
      "if=pflash,format=raw,file=" + d + "/vars.fd",
      "-drive", "if=none,id=esp,format=raw,readonly=on,file=fat:" + d + "/esp", "-device",
      "virtio-blk-pci,drive=esp",
    ]
  process.standardInput = input
  process.standardOutput = qmp
  try process.run()
  defer {
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
  try input.fileHandleForWriting.write(
    contentsOf: Data("{\"execute\":\"qmp_capabilities\"}\n".utf8))
  let deadline = ContinuousClock.now.advanced(by: .seconds(60))
  while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.1) }
  guard !process.isRunning, process.terminationStatus == 0 else {
    throw Failure("\(a): guest did not shut down normally")
  }
  let uart = try Data(contentsOf: URL(fileURLWithPath: serial))
  guard uart.range(of: Data("TARWIN-FIRMWARE-EXIT-TEST".utf8)) != nil else {
    throw Failure("\(a): probe did not run")
  }
  let messages = try Data(contentsOf: URL(fileURLWithPath: monitor)).split(separator: 10)
  let shutdown = messages.contains { line in
    guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
      event["event"] as? String == "SHUTDOWN", let data = event["data"] as? [String: Any]
    else { return false }
    return data["guest"] as? Bool == true && data["reason"] as? String == "guest-shutdown"
  }
  guard shutdown else { throw Failure("\(a): missing guest-initiated shutdown event") }
  print("\(a): EFI exit, physical page round-trip, boot queue and guest shutdown passed")
}

do { try check() } catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
