import CryptoKit
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
  let tpmEnabled = ProcessInfo.processInfo.environment["TARBOOT_TEST_TPM"] == "1"
  let state = URL(fileURLWithPath: "/tmp/tarwin-tpm-" + UUID().uuidString)
  let socket = state.appendingPathComponent("ctrl").path
  let emulator = Process()
  var tpmArgs: [String] = []
  defer {
    if tpmEnabled {
      if emulator.isRunning {
        _ = kill(emulator.processIdentifier, SIGKILL)
        emulator.waitUntilExit()
      }
      try? fm.removeItem(at: state)
    }
  }
  if tpmEnabled {
    try fm.createDirectory(
      at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    emulator.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    emulator.arguments = [
      "swtpm", "socket", "--tpm2", "--tpmstate", "dir=" + state.path,
      "--ctrl", "type=unixio,path=" + socket, "--terminate",
    ]
    try emulator.run()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while emulator.isRunning && !fm.fileExists(atPath: socket) && ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard fm.fileExists(atPath: socket) else { throw Failure("swtpm control socket unavailable") }
    let device = a == "x86_64" ? "tpm-crb" : "tpm-tis-device"
    tpmArgs = [
      "-chardev", "socket,id=tcg,path=" + socket, "-tpmdev", "emulator,id=tpm,chardev=tcg",
      "-device", device + ",tpmdev=tpm",
    ]
  }
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments =
    ["qemu-system-" + a] + machine + tpmArgs + [
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
  while process.isRunning && ContinuousClock.now < deadline {
    if tpmEnabled, let log = try? Data(contentsOf: URL(fileURLWithPath: serial)),
      log.range(of: Data("TARWIN-TCG2-NOT-FOUND".utf8)) != nil
    {
      throw Failure("\(a): UEFI reports EFI_NOT_FOUND for the TCG2 protocol")
    }
    Thread.sleep(forTimeInterval: 0.1)
  }
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
  if tpmEnabled {
    let console = String(decoding: uart, as: UTF8.self)
    func pcr(_ label: String) throws -> Data {
      let matches = console.components(separatedBy: label)
      guard matches.count == 2 else { throw Failure("missing or repeated " + label) }
      let digits = Array(matches[1].utf8.prefix(64))
      guard digits.count == 64 else { throw Failure("incomplete PCR") }
      var bytes = Data()
      for i in stride(from: 0, to: 64, by: 2) {
        guard let byte = UInt8(String(decoding: digits[i...i + 1], as: UTF8.self), radix: 16) else {
          throw Failure("invalid PCR")
        }
        bytes.append(byte)
      }
      return bytes
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: d + "/esp/BOOT.TIR"))
    for (i, payload) in [(8, archive), (9, Data(#"{"flags":[],"slot":"A"}"#.utf8))] {
      let before = try pcr("TARWIN-PCR-BEFORE-\(i)=")
      let after = try pcr("TARWIN-PCR-AFTER-\(i)=")
      guard Data(SHA256.hash(data: before + Data(SHA256.hash(data: payload)))) == after
      else { throw Failure("SHA-256 replay failed at PCR \(i)") }
    }
    print("\(a): firmware TCG2 PCR 8 and PCR 9 match independent host replay")
  }
  print(
    "\(a): ESP file read, TIRA member and ELF preflight, EFI exit, page, boot queue and shutdown passed"
  )
}

do { try check() } catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
