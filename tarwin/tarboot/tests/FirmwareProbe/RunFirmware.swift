import CryptoKit
import Darwin
import Foundation

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func guestShutdown(_ data: Data) -> Bool {
  data.split(separator: 10).contains { line in
    guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
      event["event"] as? String == "SHUTDOWN", let data = event["data"] as? [String: Any]
    else { return false }
    return data["guest"] as? Bool == true && data["reason"] as? String == "guest-shutdown"
  }
}

// QMP screendump emits binary PPM. Check the whole message on the emulated
// scanout, not a copy of framebuffer RAM or a guest-supplied success value.
private func verifyScanout(_ bytes: Data) throws {
  let lines = bytes.split(separator: 10, maxSplits: 3, omittingEmptySubsequences: false)
  guard lines.count == 4, lines[0].elementsEqual("P6".utf8), lines[2].elementsEqual("255".utf8)
    else { throw Failure("invalid QMP PPM header") }
  let dims = String(decoding: lines[1], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
  guard dims.count == 2, (66...16384).contains(dims[0]), (8...16384).contains(dims[1]),
    lines[3].count == 3 * dims[0] * dims[1] else { throw Failure("invalid QMP scanout size") }
  let glyphs: [[UInt8]] = [
    [31,4,4,4,4,4,4], [14,17,17,31,17,17,17], [30,17,17,30,20,18,17],
    [17,17,17,21,21,27,17], [14,4,4,4,4,4,14], [17,25,25,21,19,19,17],
    [0,0,0,0,0,0,0], [31,4,4,4,4,4,4], [31,16,16,30,16,16,31],
    [15,16,16,14,1,1,30], [31,4,4,4,4,4,4],
  ]
  let pixels = lines[3]
  for (cell, glyph) in glyphs.enumerated() {
    for y in 0..<8 {
      for x in 0..<6 {
        let i = pixels.startIndex + 3 * (y * dims[0] + cell * 6 + x)
        let lit = y < 7 && x < 5 && glyph[y] & (16 >> x) != 0
        guard pixels[i] == (lit ? 255 : 16), pixels[i+1] == (lit ? 255 : 32),
          pixels[i+2] == (lit ? 255 : 64) else { throw Failure("wrong scanout pixel at \(cell * 6 + x),\(y)") }
      }
    }
  }
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
  let displayEnabled = ProcessInfo.processInfo.environment["TARBOOT_TEST_DISPLAY"] == "1"
  let displayArgs = !displayEnabled ? [] : (a == "x86_64" ? ["-vga", "std"] : ["-device", "ramfb"]) + ["-no-shutdown"]
  let rngEnabled = ProcessInfo.processInfo.environment["TARBOOT_TEST_RNG"] == "1"
  let rngArgs = rngEnabled ? ["-object", "rng-random,filename=/dev/urandom,id=entropy", "-device", "virtio-rng-pci,rng=entropy"] : []
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
    ["qemu-system-" + a] + machine + tpmArgs + displayArgs + rngArgs + [
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
  var captured = false
  while process.isRunning && ContinuousClock.now < deadline {
    if rngEnabled, let log = try? Data(contentsOf: URL(fileURLWithPath: serial)) {
      for marker in ["TARWIN-RNG-UNAVAILABLE", "TARWIN-PLACEMENT-FAILED"] where log.range(of: Data(marker.utf8)) != nil {
        throw Failure("\(a): " + marker)
      }
    }
    if displayEnabled && !captured {
      if let log = try? Data(contentsOf: URL(fileURLWithPath: serial)),
        log.range(of: Data("TARWIN-GOP-UNAVAILABLE".utf8)) != nil { throw Failure("\(a): no linear GOP display") }
      if let events = try? Data(contentsOf: URL(fileURLWithPath: monitor)), guestShutdown(events) {
        let msg: [String: Any] = ["execute": "screendump", "arguments": ["filename": d + "/scanout.ppm"]]
        var commands = try JSONSerialization.data(withJSONObject: msg)
        commands.append(contentsOf: "\n{\"execute\":\"quit\"}\n".utf8)
        try input.fileHandleForWriting.write(contentsOf: commands)
        captured = true
      }
    }
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
  guard guestShutdown(try Data(contentsOf: URL(fileURLWithPath: monitor)))
    else { throw Failure("\(a): missing guest-initiated shutdown event") }
  if rngEnabled { print("\(a): EFI RNG seed read and randomized exact-address reservation passed post-exit checks") }
  if displayEnabled {
    guard captured else { throw Failure("no scanout recorded") }
    let frame = try Data(contentsOf: URL(fileURLWithPath: d + "/scanout.ppm"))
    try verifyScanout(frame)
    if let dir = ProcessInfo.processInfo.environment["TARBOOT_TEST_SCANOUT_DIR"] {
      let output = URL(fileURLWithPath: dir).appendingPathComponent(a + ".ppm")
      try frame.write(to: output, options: .withoutOverwriting)
    }
    print("\(a): post-exit debug text matches QMP scanout")
  }
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
